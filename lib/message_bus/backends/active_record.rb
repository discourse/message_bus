# frozen_string_literal: true

require 'message_bus/backends/postgres'
require 'message_bus/rails/models/message'
require 'message_bus/codec/itself'
require 'message_bus/pub_sub/redis'

module MessageBus
  module Backends
    class ActiveRecord < Postgres
      class Client
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

        class << self
          def reset!(config)
            self::Client.new(config).reset!
          end
        end

        def initialize(config)
          @config = config
          @listening_on = {}
          @available = []
          @subscribe_connection = nil
          @subscribed = false
          @mutex = Mutex.new
        end

        # @param channel [String]
        # @param value [Hash]
        # @return [Integer] persisted record id
        def add(channel, value)
          Rails::Message.create(channel: channel, value: value).id
        end

        # @param backlog_id [Integer]
        # @param num_to_keep [Integer]
        # @return [void]
        def clear_global_backlog(backlog_id, num_to_keep)
          if backlog_id > num_to_keep
            Rails::Message.where('id <= ?', backlog_id - num_to_keep).delete_all
          end
        end

        # @param channel [String]
        # @param backlog_id [Integer]
        # @param num_to_keep [Integer]
        # @return [void]
        def clear_channel_backlog(channel, backlog_id, num_to_keep)
          messages_to_keep_after =
            Rails::Message.
              select(:id).
              where(channel: channel).
              where('id <= :backlog_id', backlog_id: backlog_id).
              offset(num_to_keep).
              order(id: :desc).
              limit(1)
          Rails::Message.where(channel: channel).where('id <= (?)', messages_to_keep_after).delete_all
        end

        # @param max_backlog_age [Integer] age in seconds
        # @return [void]
        def expire(max_backlog_age)
          Rails::Message.where('added_at < ?', Time.current - max_backlog_age.seconds).delete_all
        end

        # @param channel [String]
        # @param backlog_id [Integer]
        # @return [Array<Array<Integer, Hash>>]
        def backlog(channel, backlog_id)
          Rails::Message.where(channel: channel).where('id > ?', backlog_id).order(id: :asc).pluck(:id, :value)
        end

        # @param backlog_id [Integer]
        # @return [Array<Array<Integer, String, Hash>>]
        def global_backlog(backlog_id)
          Rails::Message.where('id > ?', backlog_id).order(id: :asc).pluck(:id, :channel, :value)
        end

        # @param channel [String]
        # @param id [Integer]
        # @return [Hash, nil]
        def get_value(channel, id)
          Rails::Message.find_by(channel: channel, id: id)&.value
        end

        # @return [void]
        def after_fork
          sync do
            @listening_on.clear
          end
        end

        # Dangerous, truncates the message_bus table containing the backlog if it exists.
        # @return [void]
        def reset!
          Rails::Message.connection.execute("TRUNCATE TABLE #{Rails::Message.table_name} RESTART IDENTITY")
        end

        # It is supposed to close all connections from connection pool. We don't need this - ActiveRecord manages
        # connection pool
        def destroy
        end

        # Use with extreme care, will nuke all of the data
        # @return [void]
        def expire_all_backlogs!
          reset!
        end

        # @param channel [String, nil]
        # @return [Integer]
        def max_id(channel = nil)
          rel = Rails::Message.all
          rel = rel.where(channel: channel) if channel
          rel.maximum(:id).to_i
        end

        # @param channels [String]
        # @return [Array<Integer>]
        def max_ids(*channels)
          channels_info = Rails::Message.where(channel: channels).group(:channel).maximum(:id)
          channels_info.each_with_object(Array.new(channels.size, 0)) do |(channel, max_id), result|
            result[channels.index(channel)] = max_id
          end
        end

        # @param channel [String]
        # @param data [String]
        # @return [void]
        def publish(channel, data)
          pub_sub_instance.publish(channel, data)
        end

        # Subscribed to the given channel. This operation blocks current thread
        # @param channel [String]
        # @return [void]
        def subscribe(channel)
          obj = Object.new
          sync { @listening_on[channel] = obj }
          listener = Listener.new
          yield listener

          listener.do_sub.call
          while listening_on?(channel, obj)
            pub_sub_instance.subscribe(channel) do |_, payload|
              break unless listening_on?(channel, obj)

              listener.do_message.call(nil, payload)
            end
          end
          listener.do_unsub.call
        end

        # @return [void]
        def unsubscribe
          sync { @listening_on.clear }
        end

        private

        # @return [MessageBus::PubSub::Redis]
        def pub_sub_instance
          PubSub::Redis.new(url: @config[:pubsub_redis_url])
        end

        # @param channel [String]
        # @param obj [Object]
        # @return [Boolean]
        def listening_on?(channel, obj)
          sync { @listening_on[channel] == obj }
        end

        # @return [void]
        def sync
          @mutex.synchronize { yield }
        end
      end

      private

      # @return [MessageBus::Backends::ActiveRecord::Client]
      def client
        @client || @mutex.synchronize { @client ||= Client.new(@config) }
      end
    end
  end
end

MessageBus::BACKENDS[:active_record] = MessageBus::Backends::ActiveRecord
MessageBus.configure(transport_codec: MessageBus::Codec::Itself.new)
