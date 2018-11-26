# frozen_string_literal: true

require "message_bus/backends"

module MessageBus
  module Backends
    # Backends provide a consistent API over a variety of options for persisting
    # published messages. The API they present is around the publication to and
    # reading of messages from those backlogs in a manner consistent with
    # message_bus' philosophy.
    #
    # The heart of the message bus, a backend acts as two things:
    #
    # 1. A channel multiplexer
    # 2. Backlog storage per-multiplexed channel.
    #
    # Backends manage and expose multiple backlogs:
    #
    # * A backlog for each channel, in which messages that were published to
    #   that channel are stored.
    # * A global backlog, which conceptually stores all published messages,
    #   regardless of the channel to which they were published.
    #
    # Backlog storage mechanisms and schemas are up to each individual backend
    # implementation, and some backends store messages very differently than
    # others. It is not necessary in order to be considered a valid backend,
    # to, for example, store each channel backlog as a separate collection.
    # As long as the API is presented per this documentation, the backend is
    # free to make its own storage and performance optimisations.
    #
    # The concept of a per-channel backlog permits for lookups of messages in
    # a manner that is optimised for the use case of a subscriber catching up
    # from a message pointer, while a global backlog allows for optimising the
    # case where another system subscribes to the firehose of messages, for
    # example a message_bus server receiving all publications for delivery
    # to subscribed clients.
    #
    # Backends are fully responsible for maintaining their storage, including
    # any pruning or expiration of that storage that is necessary. message_bus
    # allows for several options for limiting the required storage capacity
    # by either backlog size or the TTL of messages in a backlog. Backends take
    # these settings and effect them either forcibly or by delegating to their
    # storage mechanism.
    #
    # Message which are published to message_bus have two IDs; one which they
    # are known by in the channel-specific backlog that they are published to,
    # and another (the "global ID") which is unique across all channels and by
    # which the message can be found in the global backlog. IDs are all
    # sequential integers starting at 0.
    #
    # @abstract
    class Base
      # rubocop:disable Lint/UnusedMethodArgument

      # Raised to indicate that the concrete backend implementation does not implement part of the API
      ConcreteClassMustImplementError = Class.new(StandardError)

      # @return [String] a special message published to trigger termination of backend subscriptions
      UNSUB_MESSAGE = "$$UNSUBSCRIBE"

      # @return [Boolean] The subscription state of the backend
      attr_reader :subscribed
      # @return [Integer] the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      attr_accessor :max_backlog_size
      # @return [Integer] the largest permitted size (number of messages) for the global backlog; beyond this capacity, old messages will be dropped.
      attr_accessor :max_global_backlog_size
      # @return [Integer] the longest amount of time a message may live in a backlog before beging removed, in seconds.
      attr_accessor :max_backlog_age
      # Typically, backlogs are trimmed whenever we publish to them. This setting allows some tolerance in order to improve performance.
      # @return [Integer] the interval of publications between which the backlog will not be cleared.
      attr_accessor :clear_every
      # @return [Integer] the largest permitted size (number of messages) to be held in a memory buffer when publication fails, for later re-publication.
      attr_accessor :max_in_memory_publish_backlog

      # @param [Hash] config backend-specific configuration options; see the concrete class for details
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(config = {}, max_backlog_size = 1000); end

      # Performs routines specific to the backend that are necessary after a process fork, typically triggerd by a forking webserver. Typically this re-opens sockets to the backend.
      def after_fork
        raise ConcreteClassMustImplementError
      end

      # Deletes all message_bus data from the backend. Use with extreme caution.
      def reset!
        raise ConcreteClassMustImplementError
      end

      # Deletes all backlogs and their data. Does not delete non-backlog data that message_bus may persist, depending on the concrete backend implementation. Use with extreme caution.
      # @abstract
      def expire_all_backlogs!
        raise ConcreteClassMustImplementError
      end

      # Publishes a message to a channel
      #
      # @param [String] channel the name of the channel to which the message should be published
      # @param [JSON] data some data to publish to the channel. Must be an object that can be encoded as JSON
      # @param [Hash] opts
      # @option opts [Boolean] :queue_in_memory (true) whether or not to hold the message in an in-memory buffer if publication fails, to be re-tried later
      # @option opts [Integer] :max_backlog_age (`self.max_backlog_age`) the longest amount of time a message may live in a backlog before beging removed, in seconds
      # @option opts [Integer] :max_backlog_size (`self.max_backlog_size`) the largest permitted size (number of messages) for the channel backlog; beyond this capacity, old messages will be dropped
      #
      # @return [Integer] the channel-specific ID the message was given
      def publish(channel, data, opts = nil)
        raise ConcreteClassMustImplementError
      end

      # Get the ID of the last message published on a channel
      #
      # @param [String] channel the name of the channel in question
      #
      # @return [Integer] the channel-specific ID of the last message published to the given channel
      def last_id(channel)
        raise ConcreteClassMustImplementError
      end

      # Get messages from a channel backlog
      #
      # @param [String] channel the name of the channel in question
      # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
      #
      # @return [Array<MessageBus::Message>] all messages published to the specified channel since the specified last ID
      def backlog(channel, last_id = 0)
        raise ConcreteClassMustImplementError
      end

      # Get messages from the global backlog
      #
      # @param [#to_i] last_id the global ID of the last message that the caller received
      #
      # @return [Array<MessageBus::Message>] all messages published on any channel since the specified last ID
      def global_backlog(last_id = 0)
        raise ConcreteClassMustImplementError
      end

      # Get a specific message from a channel
      #
      # @param [String] channel the name of the channel in question
      # @param [Integer] message_id the channel-specific ID of the message required
      #
      # @return [MessageBus::Message, nil] the requested message, or nil if it does not exist
      def get_message(channel, message_id)
        raise ConcreteClassMustImplementError
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
        raise ConcreteClassMustImplementError
      end

      # Causes all subscribers to the bus to unsubscribe, and terminates the local connection. Typically used to reset tests.
      def global_unsubscribe
        raise ConcreteClassMustImplementError
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
        raise ConcreteClassMustImplementError
      end

      # rubocop:enable Lint/UnusedMethodArgument
    end
  end
end
