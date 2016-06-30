class MessageBus::Message
  INDEX_MAP={0=> :global_id, 1=> :message_id, 2=> :channel, 3=> :data}
  attr_accessor :site_id, :user_ids, :group_ids, :client_ids, :global_id,:message_id,:channel,:data
  
  def initialize(_gi,_mi,_ch,_da)
    @global_id = _gi
    @message_id = _mi
    @channel = _ch
    @data = _da
  end
  
  def self.decode(encoded)
    s1 = encoded.index("|")
    s2 = encoded.index("|", s1+1)
    s3 = encoded.index("|", s2+1)

    MessageBus::Message.new(encoded[0..s1].to_i, encoded[s1+1..s2].to_i,
                            encoded[s2+1..s3-1].gsub("$$123$$", "|"), encoded[s3+1..-1])
  end

  # only tricky thing to encode is pipes in a channel name ... do a straight replace
  def encode
    global_id.to_s << "|" << message_id.to_s << "|" << channel.gsub("|","$$123$$") << "|" << data
  end
  
  def[](key)
    if key.is_a?(Integer)
      self.send(INDEX_MAP[key])
    else
      self.send(key)  
    end  
  end
  def ==(other)
    (@global_id == other.global_id) || (@message_id == other.message_id) || (@channel == other.channel) || (@data == other.data)
  end  
end
