# frozen_string_literal: true

require 'redis'
require 'digest'
require 'securerandom'

require "message_bus/backends/base"

module MessageBus
  module Backends
    # The Redis Streaks backend stores published messages in Redis Streams
    # (using XADD, where the ID is based on an insertion time of 0 and the
    # message_bus message ID), one for each channel (where the full message
    # is stored), and also in a global backlog as a simple pointer to the
    # respective channel and channel-specific ID. Actively subscribed
    # message_bus servers consume published messages in real-time using the
    # Redis XREAD command and forward them to subscribers, and can catch up
    # by simply altering the arguments to the same mechanism.
    #
    # Message lookup is performed using the Redis XRANGE command, and backlog
    # trimming is performed automatically by Redis. The last used
    # channel-specific and global IDs are stored as integers in simple Redis
    # keys and incremented on publication.
    #
    # Publication is implemented using a Lua script to ensure that it is
    # atomic and messages are not corrupted by parallel publication.
    #
    # @note This backend diverges from the standard in Base in the following ways:
    #
    #   * `max_backlog_age` options in this backend differ from the behaviour of
    #     other backends, in that either no messages are removed (when
    #     publications happen more regularly than this time-frame) or all
    #     messages are removed (when no publication happens during this
    #     time-frame).
    #
    #   * `clear_every` is not a supported option for this backend.
    #
    # @see Base general information about message_bus backends
    class RedisStreams < Base
      # @param [Hash] redis_config in addition to the options listed, see https://github.com/redis/redis-rb for other available options
      # @option redis_config [Logger] :logger a logger to which logs will be output
      # @option redis_config [Boolean] :enable_redis_logger (false) whether or not to enable logging by the underlying Redis library
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(redis_config = {}, max_backlog_size = 1000)
        @redis_config = redis_config.dup
        @logger = @redis_config[:logger]
        unless @redis_config[:enable_redis_logger]
          @redis_config[:logger] = nil
        end
        @max_backlog_size = max_backlog_size
        @max_global_backlog_size = 2000
        @max_in_memory_publish_backlog = 1000
        @in_memory_backlog = []
        @lock = Mutex.new
        @flush_backlog_thread = nil
        # after 7 days inactive backlogs will be removed
        @max_backlog_age = 604800
      end

      # Reconnects to Redis; used after a process fork, typically triggerd by a forking webserver
      # @see Base#after_fork
      def after_fork
        pub_redis.disconnect!
      end

      # (see Base#reset!)
      def reset!
        pub_redis.keys("__mb_*").each do |k|
          pub_redis.del k
        end
      end

      # Deletes all backlogs and their data. Does not delete ID pointers, so new publications will get IDs that continue from the last publication before the expiry. Use with extreme caution.
      # @see Base#expire_all_backlogs!
      def expire_all_backlogs!
        pub_redis.keys("__mb_*backlogstream*").each do |k|
          pub_redis.del k
        end
      end

      # Note, the script takes care of all expiry of keys, however
      # we do not expire the global backlog key cause we have no simple way to determine what it should be on publish
      # we do not provide a mechanism to set a global max backlog age, only a per-channel which we can override on publish
      LUA_PUBLISH = <<LUA

      local start_payload = ARGV[1]
      local max_backlog_age = ARGV[2]
      local max_backlog_size = tonumber(ARGV[3])
      local max_global_backlog_size = tonumber(ARGV[4])
      local channel = ARGV[5]

      local global_id_key = KEYS[1]
      local backlog_id_key = KEYS[2]
      local backlog_key = KEYS[3]
      local global_backlog_key = KEYS[4]

      local global_id = redis.call("INCR", global_id_key)
      local backlog_id = redis.call("INCR", backlog_id_key)
      local payload = string.format("%i|%i|%s", global_id, backlog_id, start_payload)
      local global_backlog_message = string.format("%i|%s", backlog_id, channel)

      redis.call("XADD", backlog_key, "MAXLEN", max_backlog_size, string.format("0-%i", backlog_id), "payload", payload)
      redis.call("EXPIRE", backlog_key, max_backlog_age)
      redis.call("XADD", global_backlog_key, "MAXLEN", max_global_backlog_size, string.format("0-%i", global_id), "payload", global_backlog_message)
      redis.call("EXPIRE", global_backlog_key, max_backlog_age)

      redis.call("EXPIRE", backlog_id_key, max_backlog_age)

      return backlog_id
LUA

      LUA_PUBLISH_SHA1 = Digest::SHA1.hexdigest(LUA_PUBLISH)

      # (see Base#publish)
      def publish(channel, data, opts = nil)
        queue_in_memory = (opts && opts[:queue_in_memory]) != false

        max_backlog_age = (opts && opts[:max_backlog_age]) || self.max_backlog_age
        max_backlog_size = (opts && opts[:max_backlog_size]) || self.max_backlog_size

        redis = pub_redis
        backlog_id_key = backlog_id_key(channel)
        backlog_key = backlog_key(channel)

        msg = MessageBus::Message.new nil, nil, channel, data

        cached_eval(
          redis,
          LUA_PUBLISH,
          LUA_PUBLISH_SHA1,
          argv: [
            msg.encode_without_ids,
            max_backlog_age,
            max_backlog_size,
            max_global_backlog_size,
            channel
          ],
          keys: [
            global_id_key,
            backlog_id_key,
            backlog_key,
            global_backlog_key
          ]
        )
      rescue ::Redis::CommandError => e
        if queue_in_memory && e.message =~ /READONLY/
          @lock.synchronize do
            @in_memory_backlog << [channel, data]
            if @in_memory_backlog.length > @max_in_memory_publish_backlog
              @in_memory_backlog.delete_at(0)
              @logger.warn("Dropping old message cause max_in_memory_publish_backlog is full: #{e.message}\n#{e.backtrace.join('\n')}")
            end
          end

          if @flush_backlog_thread == nil
            @lock.synchronize do
              if @flush_backlog_thread == nil
                @flush_backlog_thread = Thread.new { ensure_backlog_flushed }
              end
            end
          end
          nil
        else
          raise
        end
      end

      # (see Base#last_id)
      def last_id(channel)
        backlog_id_key = backlog_id_key(channel)
        pub_redis.get(backlog_id_key).to_i
      end

      # (see Base#backlog)
      def backlog(channel, last_id = nil)
        redis = pub_redis
        backlog_key = backlog_key(channel)
        start = if last_id
          "0-#{last_id + 1}"
        else
          "-"
        end
        items = redis.xrange backlog_key, start, "+"

        items.map do |_id, (_, payload)|
          MessageBus::Message.decode(payload)
        end
      end

      # (see Base#global_backlog)
      def global_backlog(last_id = nil)
        last_id = last_id.to_i
        redis = pub_redis
        start = if last_id
          "0-#{last_id + 1}"
        else
          "-"
        end
        items = redis.xrange global_backlog_key, start, "+"

        items.map! do |_id, (_, payload)|
          message_from_global_backlog(payload)
        end

        items.compact!
        items
      end

      # (see Base#get_message)
      def get_message(channel, message_id)
        redis = pub_redis
        backlog_key = backlog_key(channel)

        items = redis.xrange backlog_key, "0-#{message_id}", "0-#{message_id}"
        if items && items[0]
          _id, (_, payload) = items[0]
          MessageBus::Message.decode(payload)
        else
          nil
        end
      end

      # (see Base#subscribe)
      def subscribe(channel, last_id = nil)
        # trivial implementation for now,
        #   can cut down on connections if we only have one global subscriber
        raise ArgumentError unless block_given?

        if last_id
          # we need to translate this to a global id, at least give it a shot
          #   we are subscribing on global and global is always going to be bigger than local
          #   so worst case is a replay of a few messages
          message = get_message(channel, last_id)
          if message
            last_id = message.global_id
          end
        end
        global_subscribe(last_id) do |m|
          yield m if m.channel == channel
        end
      end

      # (see Base#global_unsubscribe)
      def global_unsubscribe
        if @redis_global
          # new connection to avoid deadlock
          new_redis_connection.xadd(unsubscribe_key, "*", UNSUB_MESSAGE, true)
          @redis_global.quit
        end
      end

      # (see Base#global_subscribe)
      def global_subscribe(last_id = nil)
        raise ArgumentError unless block_given?

        highest_id = last_id

        begin
          @redis_global = new_redis_connection

          last_unsubscribe_seen, = @redis_global.xrevrange(unsubscribe_key, "+", "-", "COUNT", "1").last

          unless highest_id
            last_message_id, = @redis_global.xrevrange(global_backlog_key, "+", "-", "COUNT", "1").last
            if last_message_id
              highest_id = last_message_id.split("-").last.to_i
            end
          end

          subscription_id = SecureRandom.uuid
          @redis_global.setex(subscription_key(subscription_id), 5, true)

          @subscribed = true

          loop do
            # If Redis doesn't know about our subscription any more, the stream might also have been reset.
            # Assume that our stream pointer is no good and start reading the stream from the beginning again.
            unless @redis_global.get(subscription_key(subscription_id)) == "true"
              @logger.warn "Subscription #{subscription_id} expired. Reading full backlog."
              highest_id = nil
            end
            @redis_global.setex(subscription_key(subscription_id), 5, true)

            start = highest_id ? "0-#{highest_id}" : 0

            response = @redis_global.xread("BLOCK", 1000, "STREAMS", global_backlog_key, unsubscribe_key, start || 0, last_unsubscribe_seen || 0)
            next unless response

            stream, messages = response.first

            return if stream == unsubscribe_key

            messages.each do |_id, (_, payload)|
              m = message_from_global_backlog(payload)

              if m && (highest_id.nil? || m.global_id > highest_id)
                highest_id = m.global_id
                yield m
              end
            end
          end
        rescue => error
          @logger.warn "#{error.class}: #{error} subscribe failed, reconnecting in 1 second. Call stack #{error.backtrace}"
          sleep 1
          retry
        ensure
          @subscribed = false
        end
      end

      private

      def new_redis_connection
        ::Redis.new(@redis_config)
      end

      # redis connection used for publishing messages
      def pub_redis
        @pub_redis ||= new_redis_connection
      end

      def backlog_key(channel)
        "__mb_backlogstream_n_#{channel}"
      end

      def backlog_id_key(channel)
        "__mb_backlog_id_n_#{channel}"
      end

      def global_id_key
        "__mb_global_id_n"
      end

      def global_backlog_key
        "__mb_global_backlogstream_n"
      end

      def subscription_key(id)
        "__mb_subscription_n_#{id}"
      end

      def unsubscribe_key
        "__mb_unsubscribe_n"
      end

      def message_from_global_backlog(payload)
        pipe = payload.index "|"
        message_id = payload[0..pipe].to_i
        channel = payload[pipe + 1..-1]
        get_message(channel, message_id)
      end

      def cached_eval(redis, script, script_sha1, params)
        begin
          redis.evalsha script_sha1, params
        rescue ::Redis::CommandError => e
          if e.to_s =~ /^NOSCRIPT/
            redis.eval script, params
          else
            raise
          end
        end
      end

      def is_readonly?
        key = "__mb_is_readonly"

        begin
          # in case we are not connected to the correct server
          # which can happen when sharing ips
          pub_redis.client.reconnect
          pub_redis.client.call([:set, key, '1'])
          false
        rescue ::Redis::CommandError => e
          return true if e.message =~ /^READONLY/
        end
      end

      def ensure_backlog_flushed
        flushed = false

        while !flushed
          try_again = false

          if is_readonly?
            sleep 1
            next
          end

          @lock.synchronize do
            if @in_memory_backlog.length == 0
              flushed = true
              break
            end

            begin
              # TODO recover special options
              publish(*@in_memory_backlog[0], queue_in_memory: false)
            rescue ::Redis::CommandError => e
              if e.message =~ /^READONLY/
                try_again = true
              else
                @logger.warn("Dropping undeliverable message: #{e.message}\n#{e.backtrace.join('\n')}")
              end
            rescue => e
              @logger.warn("Dropping undeliverable message: #{e.message}\n#{e.backtrace.join('\n')}")
            end

            @in_memory_backlog.delete_at(0) unless try_again
          end
        end
      ensure
        @lock.synchronize do
          @flush_backlog_thread = nil
        end
      end

      MessageBus::BACKENDS[:redis_streams] = self
    end
  end
end
