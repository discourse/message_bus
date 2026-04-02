# frozen_string_literal: true

# Represents a published message and its encoding for persistence.
class MessageBus::Message
  attr_accessor :global_id, :message_id, :channel, :data,
                :site_id, :user_ids, :group_ids, :client_ids

  def initialize(global_id, message_id, channel, data)
    @global_id = global_id
    @message_id = message_id
    @channel = channel
    @data = data
  end

  def self.decode(encoded)
    s1 = encoded.index("|")
    s2 = encoded.index("|", s1 + 1)
    s3 = encoded.index("|", s2 + 1)

    global_id  = encoded[0, s1 + 1].to_i
    message_id = encoded[(s1 + 1), (s2 - s1 - 1)].to_i
    channel    = encoded[(s2 + 1), (s3 - s2 - 1)]
    channel.gsub!("$$123$$", "|")
    data = encoded[(s3 + 1), encoded.size]

    new(global_id, message_id, channel, data)
  end

  # only tricky thing to encode is pipes in a channel name ... do a straight replace
  def encode
    "#{global_id}|#{message_id}|#{channel.gsub("|", "$$123$$")}|#{data}"
  end

  def encode_without_ids
    "#{channel.gsub("|", "$$123$$")}|#{data}"
  end

  def ==(other)
    other.is_a?(self.class) &&
      self.global_id == other.global_id &&
      self.message_id == other.message_id &&
      self.channel == other.channel &&
      self.data == other.data
  end
end
