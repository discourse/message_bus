# frozen_string_literal: true

require 'json'

# Represents a published message and its encoding for persistence.
class MessageBus::Message < Struct.new(:global_id, :message_id, :channel, :data)
  attr_accessor :site_id, :user_ids, :group_ids, :client_ids

  # @param encoded [String]
  # @return [MessageBus::Message]
  def self.decode(encoded)
    global_id, message_id, channel, data = JSON.parse(encoded)

    MessageBus::Message.new(global_id.to_i, message_id.to_i, channel, data)
  end

  # @return [String] a JSON representation of a MessageBus::Message
  def encode
    [global_id, message_id, channel, data].to_json
  end

  # @return [String] a JSON representation of a MessageBus::Message
  def encode_without_ids
    [nil, nil, channel, data].to_json
  end
end
