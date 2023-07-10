# frozen_string_literal: true

require_relative '../pub_sub_implementation'
gem 'redis', '>= 5' # Require redis gem v5+
require 'redis'

module MessageBus
  module PubSub
    class Redis
      include PubSubImplementation

      # @param url [String]
      def initialize(url:)
        @redis = ::Redis.new(url: url)
      end

      # @param channel [String]
      # @param data [String]
      # @return [void]
      def publish(channel, data)
        @redis.publish(channel, data)
      end

      # @param channel [String]
      # @param timeout [Integer]
      # @yield [channel, message]
      # @return [void]
      def subscribe(channel, timeout: 10, &blk)
        @redis.subscribe_with_timeout(timeout, channel) do |on|
          on.message do |sub_channel, message|
            yield sub_channel, message
          end
        end
      end
    end
  end
end
