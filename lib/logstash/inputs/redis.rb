# encoding: utf-8
require "logstash/namespace"
require "logstash/inputs/base"
require "logstash/inputs/threadable"
require 'redis'
require "stud/interval"

# This input will read events from a Redis instance; it supports both Redis channels and lists.
# The list command (BLPOP) used by Logstash is supported in Redis v1.3.1+, and
# the channel commands used by Logstash are found in Redis v1.3.8+.
# While you may be able to make these Redis versions work, the best performance
# and stability will be found in more recent stable versions.  Versions 2.6.0+
# are recommended.
#
# For more information about Redis, see <http://redis.io/>
#
# `batch_count` note: If you use the `batch_count` setting, you *must* use a Redis version 2.6.0 or
# newer. Anything older does not support the operations used by batching.
#
module LogStash
  module Inputs
    class Redis < LogStash::Inputs::Threadable

      BATCH_EMPTY_SLEEP = 0.25

      config_name 'redis'

      default :codec, 'json'

      # The hostname of your Redis server.
      config :host, validate: :string, default: '127.0.0.1'

      # Redis sentinel host
      config :sentinel_host, validate: :string

      # Redis sentinel count
      config :sentinel_count, validate: :number, default: 3

      # Each sentinel port.
      config :sentinel_port, validate: :number, default: 26_379

      # Sentinel host
      config :sentinel, validate: :string, default: 'redis-cluster-headless.app.svc.cluster.local'

      # Redis app name
      config :name, validate: :string

      # The port to connect on.
      config :port, validate: :number, default: 6379

      # SSL
      config :ssl, validate: :boolean, default: false

      # The unix socket path to connect on. Will override host and port if defined.
      # There is no unix socket path by default.
      config :path, validate: :string

      # The Redis database number.
      config :db, validate: :number, default: 0

      # Initial connection timeout in seconds.
      config :timeout, validate: :number, default: 5

      # Password to authenticate with. There is no authentication by default.
      config :password, validate: :password

      # The name of a Redis list or channel.
      config :key, validate: :string, required: true

      # Specify either list or channel.  If `data_type` is `list`, then we will BLPOP the
      # key.  If `data_type` is `channel`, then we will SUBSCRIBE to the key.
      # If `data_type` is `pattern_channel`, then we will PSUBSCRIBE to the key.
      config :data_type, validate: %w[list channel pattern_channel], required: true

      # The number of events to return from Redis using EVAL.
      config :batch_count, validate: :number, default: 125

      # Redefined Redis commands to be passed to the Redis client.
      config :command_map, validate: :hash, default: {}

      public

      def register
        @redis_url = if @sentinel.length.zero?
                       @path.nil? ? "redis://#{@password}@#{@host}:#{@port}/#{@db}" : "#{@password}@#{@path}/#{@db}"
                     else
                       "redis://@#{@sentinel_host}"
                     end

        # just switch on data_type once
        if @data_type == 'list' || @data_type == 'dummy'
          @run_method = method(:list_runner)
          @stop_method = method(:list_stop)
        elsif @data_type == 'channel'
          @run_method = method(:channel_runner)
          @stop_method = method(:subscribe_stop)
        elsif @data_type == 'pattern_channel'
          @run_method = method(:pattern_channel_runner)
          @stop_method = method(:subscribe_stop)
        end

        @list_method = batched? ? method(:list_batch_listener) : method(:list_single_listener)

        @identity = "#{name} - #{@redis_url} - #{@data_type}:#{@key}"
        @logger.info('Registering Redis', identity: @identity)
      end

      def run(output_queue)
        @run_method.call(output_queue)
      rescue LogStash::ShutdownSignal
        # ignore and quit
      end

      def stop
        @stop_method.call
      end

      # private methods -----------------------------
      private

      def batched?
        @batch_count > 1
      end

      # private
      def is_list_type?
        @data_type == 'list'
      end

      # private
      def redis_params
        params = {
          timeout: @timeout,
          db: @db,
          password: @password.nil? ? nil : @password.value,
          ssl: @ssl
        }

        if @path.nil? && @sentinel_host.length.zero?
          params[:host] = @host
          params[:port] = @port
        elsif @path.nil? && @sentinel_host.length > 0
          params[:url] = "redis://#{@sentinel_host}"
          params[:role] = :master
          params[:sentinels] = sentinel_connection_params
        else
          @logger.warn("Parameter 'path' is set, ignoring parameters: 'host' and 'port'")
          params[:path] = @path
        end

        params
      end

      def sentinel_connection_params
        @sentinel_count.times.map do
          { host: @sentinel, port: @sentinel_port }
        end
      end

      def new_redis_instance
        @logger.warn("Redis Params:- #{redis_params}")
        ::Redis.new(redis_params)
      end

      # private
      def connect
        redis = new_redis_instance

        # register any renamed Redis commands
        @command_map.each do |name, renamed|
          redis._client.command_map[name.to_sym] = renamed.to_sym
        end

        load_batch_script(redis) if batched? && is_list_type?

        redis
      end 

      # private
      def load_batch_script(redis)
        # A Redis Lua EVAL script to fetch a count of keys
        redis_script = <<EOF
          local batchsize = tonumber(ARGV[1])
          local result = redis.call(\'#{@command_map.fetch('lrange', 'lrange')}\', KEYS[1], 0, batchsize)
          redis.call(\'#{@command_map.fetch('ltrim', 'ltrim')}\', KEYS[1], batchsize + 1, -1)
          return result
EOF
        @redis_script_sha = redis.script(:load, redis_script)
      end

      # private
      def queue_event(msg, output_queue, channel=nil)
        begin
          @codec.decode(msg) do |event|
            decorate(event)
            event.set("[@metadata][redis_channel]", channel) if !channel.nil?
            output_queue << event
          end
        rescue => e # parse or event creation error
          @logger.error('Failed to create event', message: msg, exception: e, backtrace: e.backtrace)
        end
      end

      # private
      def list_stop
        redis = @redis # might change during method invocation
        return if redis.nil? || !redis.connected?

        redis.quit rescue nil # does client.disconnect internally
        # check if input retried while executing
        list_stop unless redis.equal? @redis
        @redis = nil
      end

      # private
      def list_runner(output_queue)
        while !stop?
          begin
            @redis ||= connect
            @list_method.call(@redis, output_queue)
          rescue => e
            log_error(e)
            retry if reset_for_error_retry(e)
          end
        end
      end

      def list_batch_listener(redis, output_queue)
        begin
          results = redis.evalsha(@redis_script_sha, [@key], [@batch_count-1])
          results.each do |item|
            queue_event(item, output_queue)
          end

          if results.size.zero?
            sleep BATCH_EMPTY_SLEEP
          end

          # Below is a commented-out implementation of 'batch fetch'
          # using pipelined LPOP calls. This in practice has been observed to
          # perform exactly the same in terms of event throughput as
          # the evalsha method. Given that the EVALSHA implementation uses
          # one call to Redis instead of N (where N == @batch_count) calls,
          # I decided to go with the 'evalsha' method of fetching N items
          # from Redis in bulk.
          #redis.pipelined do
            #error, item = redis.lpop(@key)
            #(@batch_count-1).times { redis.lpop(@key) }
          #end.each do |item|
            #queue_event(item, output_queue) if item
          #end
          # --- End commented out implementation of 'batch fetch'
          # further to the above, the LUA script now uses lrange and trim
          # which should further improve the efficiency of the script
        rescue ::Redis::CommandError => e
          if e.to_s =~ /NOSCRIPT/
            @logger.warn('Redis may have been restarted, reloading Redis batch EVAL script', exception: e)
            load_batch_script(redis)
            retry
          else
            raise e
          end
        end
      end

      def list_single_listener(redis, output_queue)
        item = redis.blpop(@key, 0, timeout: 1)
        return unless item # from timeout or other conditions

        # blpop returns the 'key' read from as well as the item result
        # we only care about the result (2nd item in the list).
        queue_event(item.last, output_queue)
      end

      # private
      def subscribe_stop
        redis = @redis # might change during method invocation
        return if redis.nil? || !redis.connected?

        if redis.subscribed?
          if @data_type == 'pattern_channel'
            redis.punsubscribe
          else
            redis.unsubscribe
          end
        end
        redis.close rescue nil # does client.disconnect
        # check if input retried while executing
        subscribe_stop unless redis.equal? @redis
        @redis = nil
      end

      # private
      def redis_runner
        begin
          @redis ||= connect
          yield
        rescue => e
          log_error(e)
          retry if reset_for_error_retry(e)
        end
      end

      def log_error(e)
        info = { message: e.message, exception: e.class }
        info[:backtrace] = e.backtrace if @logger.debug?

        case e
        when ::Redis::TimeoutError
          # expected for channels in case no data is available
          @logger.debug('Redis timeout, retrying', info)
        when ::Redis::BaseConnectionError, ::Redis::ProtocolError
          @logger.warn('Redis connection error', info)
        when ::Redis::BaseError
          @logger.error('Redis error', info)
        when ::LogStash::ShutdownSignal
          @logger.debug('Received shutdown signal')
        else
          info[:backtrace] ||= e.backtrace
          @logger.error('Unexpected error', info)
        end
      end

      # @return [true] if operation is fine to retry
      def reset_for_error_retry(e)
        return if e.is_a?(::LogStash::ShutdownSignal)

        # Reset the redis variable to trigger reconnect
        @redis = nil

        Stud.stoppable_sleep(1) { stop? }
        !stop? # retry if not stop-ing
      end

      # private
      def channel_runner(output_queue)
        redis_runner do
          channel_listener(output_queue)
        end
      end

      # private
      def channel_listener(output_queue)
        @redis.subscribe(@key) do |on|
          on.subscribe do |channel, count|
            @logger.info('Subscribed', channel: channel, count: count)
          end

          on.message do |channel, message|
            queue_event(message, output_queue, channel)
          end

          on.unsubscribe do |channel, count|
            @logger.info('Unsubscribed', channel: channel, count: count)
          end
        end
      end

      def pattern_channel_runner(output_queue)
        redis_runner do
          pattern_channel_listener(output_queue)
        end
      end

      # private
      def pattern_channel_listener(output_queue)
        @redis.psubscribe @key do |on|
          on.psubscribe do |channel, count|
            @logger.info('Subscribed', channel: channel, count: count)
          end

          on.pmessage do |_pattern, channel, message|
            queue_event(message, output_queue, channel)
          end

          on.punsubscribe do |channel, count|
            @logger.info('Unsubscribed', channel: channel, count: count)
          end
        end
      end
    end
  end
end
