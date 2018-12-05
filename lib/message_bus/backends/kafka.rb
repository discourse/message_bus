# frozen_string_literal: true

require 'kafka'

require "message_bus/backends/base"

module MessageBus
  module Backends
    # The Kafka backend stores published messages in Kafka topics.
    #
    # @note This backend diverges from the standard in Base in the following ways:
    #
    #   *
    #
    # @see Base general information about message_bus backends
    class Kafka < Base
      # @param [Hash] config in addition to the options listed, see https://github.com/zendesk/ruby-kafka for other available options
      # @option redis_config [Logger] :logger a logger to which logs will be output
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(config = {}, max_backlog_size = 1000)
        @config = config.dup
        @logger = @config[:logger]
        @max_backlog_size = max_backlog_size
        @max_global_backlog_size = 2000
        @max_in_memory_publish_backlog = 1000
        @in_memory_backlog = []
        @lock = Mutex.new
        @flush_backlog_thread = nil
        # after 7 days inactive backlogs will be removed
        @max_backlog_age = 604800
      end

      # Reconnects to Kafka; used after a process fork, typically triggerd by a forking webserver
      # @see Base#after_fork
      def after_fork
      end

      # (see Base#reset!)
      def reset!
      end

      # Deletes all backlogs and their data. Does not delete ID pointers, so new publications will get IDs that continue from the last publication before the expiry. Use with extreme caution.
      # @see Base#expire_all_backlogs!
      def expire_all_backlogs!
      end

      # (see Base#publish)
      def publish(channel, data, opts = nil)
        queue_in_memory = (opts && opts[:queue_in_memory]) != false

        max_backlog_age = (opts && opts[:max_backlog_age]) || self.max_backlog_age
        max_backlog_size = (opts && opts[:max_backlog_size]) || self.max_backlog_size

        redis = pub_redis
        backlog_id_key = backlog_id_key(channel)
        backlog_key = backlog_key(channel)

        msg = MessageBus::Message.new nil, nil, channel, data


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
        # pub_redis.get(backlog_id_key).to_i
      end

      # (see Base#backlog)
      def backlog(channel, last_id = 0)
        redis = pub_redis
        backlog_key = backlog_key(channel)
        items = redis.zrangebyscore backlog_key, last_id.to_i + 1, "+inf"

        items.map do |i|
          MessageBus::Message.decode(i)
        end
      end

      # (see Base#global_backlog)
      def global_backlog(last_id = 0)
        items = pub_redis.zrangebyscore global_backlog_key, last_id.to_i + 1, "+inf"

        items.map! do |i|
          pipe = i.index "|"
          message_id = i[0..pipe].to_i
          channel = i[pipe + 1..-1]
          m = get_message(channel, message_id)
          m
        end

        items.compact!
        items
      end

      # (see Base#get_message)
      def get_message(channel, message_id)
        redis = pub_redis
        backlog_key = backlog_key(channel)

        items = redis.zrangebyscore backlog_key, message_id, message_id
        if items && items[0]
          MessageBus::Message.decode(items[0])
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
          new_redis_connection.publish(redis_channel_name, UNSUB_MESSAGE)
          @redis_global.disconnect
          @redis_global = nil
        end
      end

      # (see Base#global_subscribe)
      def global_subscribe(last_id = nil, &blk)
        raise ArgumentError unless block_given?

        highest_id = last_id

        clear_backlog = lambda do
          retries = 4
          begin
            highest_id = process_global_backlog(highest_id, retries > 0, &blk)
          rescue BackLogOutOfOrder => e
            highest_id = e.highest_id
            retries -= 1
            sleep(rand(50) / 1000.0)
            retry
          end
        end

        begin
          @redis_global = new_redis_connection

          if highest_id
            clear_backlog.call(&blk)
          end

          @redis_global.subscribe(redis_channel_name) do |on|
            on.subscribe do
              if highest_id
                clear_backlog.call(&blk)
              end
              @subscribed = true
            end

            on.unsubscribe do
              @subscribed = false
            end

            on.message do |_c, m|
              if m == UNSUB_MESSAGE
                @redis_global.unsubscribe
                return
              end
              m = MessageBus::Message.decode m

              # we have 3 options
              #
              # 1. message came in the correct order GREAT, just deal with it
              # 2. message came in the incorrect order COMPLICATED, wait a tiny bit and clear backlog
              # 3. message came in the incorrect order and is lowest than current highest id, reset

              if highest_id.nil? || m.global_id == highest_id + 1
                highest_id = m.global_id
                yield m
              else
                clear_backlog.call(&blk)
              end
            end
          end
        rescue => error
          @logger.warn "#{error} subscribe failed, reconnecting in 1 second. Call stack #{error.backtrace}"
          sleep 1
          retry
        end
      end

      private

      def kafka_client
        @kafka_client ||= Kafka.new(@config[:brokers])
      end

      MessageBus::BACKENDS[:kafka] = self
    end
  end
end
