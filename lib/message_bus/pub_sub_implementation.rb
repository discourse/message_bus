# frozen_string_literal: true

module MessageBus
  module PubSubImplementation
    # Publishes a data to a channel
    # @param channel [String]
    # @param data [String]
    # @return [void]
    def publish(channel, data)
      raise NotImplementedError
    end

    # Yields the given block each time data arrive into a channel. Blocks current thread
    # @param channel [String]
    # @param timeout [Integer] setup a timeout in seconds after which the subscription will be terminated if no messages
    #   are received
    # @yield [channel, message] a channel and a message, received from that channel
    # @return [void]
    def subscribe(channel, timeout: 10, &blk)
      raise NotImplementedError
    end
  end
end
