# frozen_string_literal: true

require "message_bus/backends/base"

module MessageBus
  module Backends
    # The memory backend stores published messages in a simple array per
    # channel, and does not store a separate global backlog.
    #
    # This backend diverges from the standard in Base in the following ways:
    #
    # * Does not support forking
    # * Does not support in-memory buffering of messages on publication (redundant)
    #
    # @see Base general information about message_bus backends
    class Memory < Base
      class Client
        attr_accessor :max_backlog_age

        class Listener
          attr_reader :do_sub, :do_unsub, :do_message

          def subscribe(&block)
            @do_sub = block
          end

          def unsubscribe(&block)
            @do_unsub = block
          end

          def message(&block)
            @do_message = block
          end
        end

        class Channel
          attr_accessor :backlog, :ttl

          def initialize(ttl:)
            @backlog = []
            @ttl = ttl
          end

          def expired?
            last_publication_time = nil
            backlog.each do |_id, _value, published_at|
              if !last_publication_time || published_at > last_publication_time
                last_publication_time = published_at
              end
            end
            return true unless last_publication_time

            last_publication_time < Time.now - ttl
          end
        end

        def initialize(_config)
          @mutex = Mutex.new
          @listeners = []
          @timer_thread = MessageBus::TimerThread.new
          @timer_thread.on_error do |e|
            logger.warn "Failed to process job: #{e} #{e.backtrace}"
          end
          @timer_thread.every(1) { expire }
          reset!
        end

        def add(channel, value, max_backlog_age:)
          listeners = nil
          id = nil
          sync do
            id = @global_id += 1
            channel_object = chan(channel)
            channel_object.backlog << [id, value, Time.now]
            if max_backlog_age
              channel_object.ttl = max_backlog_age
            end
            listeners = @listeners.dup
          end
          msg = MessageBus::Message.new id, id, channel, value
          payload = msg.encode
          listeners.each { |l| l.push(payload) }
          id
        end

        def expire
          sync do
            @channels.delete_if { |_name, channel| channel.expired? }
          end
        end

        def clear_global_backlog(backlog_id, num_to_keep)
          if backlog_id > num_to_keep
            oldest = backlog_id - num_to_keep
            sync do
              @channels.each_value do |channel|
                channel.backlog.delete_if { |id, _| id <= oldest }
              end
            end
            nil
          end
        end

        def clear_channel_backlog(channel, backlog_id, num_to_keep)
          oldest = backlog_id - num_to_keep
          sync { chan(channel).backlog.delete_if { |id, _| id <= oldest } }
          nil
        end

        def backlog(channel, backlog_id)
          sync { chan(channel).backlog.select { |id, _| id > backlog_id } }
        end

        def global_backlog(backlog_id)
          sync do
            @channels.dup.flat_map do |channel_name, channel|
              channel.backlog.select { |id, _| id > backlog_id }.map { |id, value| [id, channel_name, value] }
            end.sort
          end
        end

        def get_value(channel, id)
          sync { chan(channel).backlog.find { |i, _| i == id }[1] }
        end

        # Dangerous, drops the message_bus table containing the backlog if it exists.
        def reset!
          sync do
            @global_id = 0
            @channels = {}
          end
        end

        # use with extreme care, will nuke all of the data
        def expire_all_backlogs!
          sync do
            @channels = {}
          end
        end

        def max_id(channel = nil)
          if channel
            sync do
              if entry = chan(channel).backlog.last
                entry.first
              end
            end
          else
            sync { @global_id - 1 }
          end || 0
        end

        def subscribe
          listener = Listener.new
          yield listener

          q = Queue.new
          sync do
            @listeners << q
          end

          listener.do_sub.call
          while msg = q.pop
            listener.do_message.call(nil, msg)
          end
          listener.do_unsub.call
          sync do
            @listeners.delete(q)
          end

          nil
        end

        def unsubscribe
          sync { @listeners.each { |l| l.push(nil) } }
        end

        private

        def chan(channel)
          @channels[channel] ||= Channel.new(ttl: @max_backlog_age)
        end

        def sync
          @mutex.synchronize { yield }
        end
      end

      # @param [Hash] config
      # @option config [Logger] :logger a logger to which logs will be output
      # @option config [Integer] :clear_every the interval of publications between which the backlog will not be cleared
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(config = {}, max_backlog_size = 1000)
        @config = config
        @max_backlog_size = max_backlog_size
        @max_global_backlog_size = 2000
        # after 7 days inactive backlogs will be removed
        self.max_backlog_age = 604800
        @clear_every = config[:clear_every] || 1
      end

      def max_backlog_age=(value)
        client.max_backlog_age = value
      end

      # No-op; this backend doesn't support forking.
      def after_fork
        nil
      end

      # Deletes all message_bus data from the backend. Use with extreme caution.
      def reset!
        client.reset!
      end

      # Deletes all backlogs and their data. Use with extreme caution.
      def expire_all_backlogs!
        client.expire_all_backlogs!
      end

      # Publishes a message to a channel
      #
      # @param [String] channel the name of the channel to which the message should be published
      # @param [JSON] data some data to publish to the channel. Must be an object that can be encoded as JSON
      # @param [Hash] opts
      # @option opts [Boolean] :queue_in_memory NOT SUPPORTED
      # @option opts [Integer] :max_backlog_age (`self.max_backlog_age`) the longest amount of time a message may live in a backlog before beging removed, in seconds
      # @option opts [Integer] :max_backlog_size (`self.max_backlog_size`) the largest permitted size (number of messages) for the channel backlog; beyond this capacity, old messages will be dropped
      #
      # @return [Integer] the channel-specific ID the message was given
      def publish(channel, data, opts = nil)
        c = client
        max_backlog_age = opts && opts[:max_backlog_age]
        backlog_id = c.add(channel, data, max_backlog_age: max_backlog_age)

        if backlog_id % clear_every == 0
          max_backlog_size = (opts && opts[:max_backlog_size]) || self.max_backlog_size
          c.clear_global_backlog(backlog_id, @max_global_backlog_size)
          c.clear_channel_backlog(channel, backlog_id, max_backlog_size)
        end

        backlog_id
      end

      # Get the ID of the last message published on a channel
      #
      # @param [String] channel the name of the channel in question
      #
      # @return [Integer] the channel-specific ID of the last message published to the given channel
      def last_id(channel)
        client.max_id(channel)
      end

      # Get messages from a channel backlog
      #
      # @param [String] channel the name of the channel in question
      # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
      #
      # @return [Array<MessageBus::Message>] all messages published to the specified channel since the specified last ID
      def backlog(channel, last_id = 0)
        items = client.backlog channel, last_id.to_i

        items.map! do |id, data|
          MessageBus::Message.new id, id, channel, data
        end
      end

      # Get messages from the global backlog
      #
      # @param [#to_i] last_id the global ID of the last message that the caller received
      #
      # @return [Array<MessageBus::Message>] all messages published on any channel since the specified last ID
      def global_backlog(last_id = 0)
        items = client.global_backlog last_id.to_i

        items.map! do |id, channel, data|
          MessageBus::Message.new id, id, channel, data
        end
      end

      # Get a specific message from a channel
      #
      # @param [String] channel the name of the channel in question
      # @param [Integer] message_id the channel-specific ID of the message required
      #
      # @return [MessageBus::Message, nil] the requested message, or nil if it does not exist
      def get_message(channel, message_id)
        if data = client.get_value(channel, message_id)
          MessageBus::Message.new message_id, message_id, channel, data
        else
          nil
        end
      end

      # Subscribe to messages on a particular channel. Each message since the
      # last ID specified will be delivered by yielding to the passed block as
      # soon as it is available. This will block until subscription is terminated.
      #
      # @param [String] channel the name of the channel to which we should subscribe
      # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
      #
      # @yield [message] a message-handler block
      # @yieldparam [MessageBus::Message] message each message as it is delivered
      #
      # @return [nil]
      def subscribe(channel, last_id = nil)
        # trivial implementation for now,
        #   can cut down on connections if we only have one global subscriber
        raise ArgumentError unless block_given?

        global_subscribe(last_id) do |m|
          yield m if m.channel == channel
        end
      end

      # Causes all subscribers to the bus to unsubscribe, and terminates the local connection. Typically used to reset tests.
      def global_unsubscribe
        client.unsubscribe
        @subscribed = false
      end

      # Subscribe to messages on all channels. Each message since the last ID
      # specified will be delivered by yielding to the passed block as soon as
      # it is available. This will block until subscription is terminated.
      #
      # @param [#to_i] last_id the global ID of the last message that the caller received
      #
      # @yield [message] a message-handler block
      # @yieldparam [MessageBus::Message] message each message as it is delivered
      #
      # @return [nil]
      def global_subscribe(last_id = nil)
        raise ArgumentError unless block_given?

        highest_id = last_id

        begin
          client.subscribe do |on|
            h = {}

            on.subscribe do
              if highest_id
                process_global_backlog(highest_id) do |m|
                  h[m.global_id] = true
                  yield m
                end
              end
              @subscribed = true
            end

            on.unsubscribe do
              @subscribed = false
            end

            on.message do |_c, m|
              m = MessageBus::Message.decode m

              # we have 3 options
              #
              # 1. message came in the correct order GREAT, just deal with it
              # 2. message came in the incorrect order COMPLICATED, wait a tiny bit and clear backlog
              # 3. message came in the incorrect order and is lowest than current highest id, reset

              if h
                # If already yielded during the clear backlog when subscribing,
                # don't yield a duplicate copy.
                unless h.delete(m.global_id)
                  h = nil if h.empty?
                  yield m
                end
              else
                yield m
              end
            end
          end
        rescue => error
          @config[:logger].warn "#{error} subscribe failed, reconnecting in 1 second. Call stack\n#{error.backtrace.join("\n")}"
          sleep 1
          retry
        end
      end

      private

      def client
        @client ||= new_connection
      end

      def new_connection
        Client.new(@config)
      end

      def process_global_backlog(highest_id)
        if highest_id > client.max_id
          highest_id = 0
        end

        global_backlog(highest_id).each do |old|
          yield old
          highest_id = old.global_id
        end

        highest_id
      end

      MessageBus::BACKENDS[:memory] = self
    end
  end
end
