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
    s1 = encoded.byteindex("|")
    s2 = encoded.byteindex("|", s1 + 1)
    s3 = encoded.byteindex("|", s2 + 1)

    global_id  = encoded.to_i
    message_id = encoded.byteslice(s1 + 1, s2 - s1 - 1).to_i
    channel    = encoded.byteslice(s2 + 1, s3 - s2 - 1)
    channel.gsub!("$$123$$", "|") if channel.include?("$$123$$")
    data = encoded.byteslice(s3 + 1, encoded.bytesize - s3 - 1)

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
