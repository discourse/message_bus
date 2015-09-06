class MessageBus::Client
  attr_accessor :client_id, :user_id, :group_ids, :connect_time,
                :subscribed_sets, :site_id, :cleanup_timer,
                :async_response, :io, :headers

  def initialize(opts)
    self.client_id = opts[:client_id]
    self.user_id = opts[:user_id]
    self.group_ids = opts[:group_ids] || []
    self.site_id = opts[:site_id]
    self.connect_time = Time.now
    @bus = opts[:message_bus] || MessageBus
    @subscriptions = {}
  end

  def in_async?
    @async_response || @io
  end

  def ensure_closed!
    return unless in_async?
    write_and_close "[]"
  rescue
    # we may have a dead socket, just nil the @io
    @io = nil
    @async_response = nil
  end

  def close
    return unless in_async?
    write_and_close "[]"
  end

  def closed
    !@async_response
  end

  def subscribe(channel, last_seen_id)
    bus_last_id = @bus.last_id(channel)
    last_seen_id = nil if last_seen_id == ""
    last_seen_id ||= bus_last_id
    last_seen_id = last_seen_id.to_i
    @subscriptions[channel] = last_seen_id
    if last_seen_id > bus_last_id
      @over_position = true
    end
  end

  def subscriptions
    @subscriptions
  end

  def <<(msg)
    write_and_close messages_to_json([msg])
  end

  def subscriptions
    @subscriptions
  end

  def allowed?(msg)
    allowed = !msg.user_ids || msg.user_ids.include?(self.user_id)
    allowed &&= !msg.client_ids || msg.client_ids.include?(self.client_id)
    allowed && (
      msg.group_ids.nil? ||
      msg.group_ids.length == 0 ||
      (
        msg.group_ids - self.group_ids
      ).length < msg.group_ids.length
    )
  end

  def filter(msg)
    filter = @bus.client_filter(msg.channel)

    if filter
      filter.call(self.user_id, msg)
    else
      msg
    end
  end

  def backlog(opts={})
    if @over_position && opts[:allow_flush]
      return [MessageBus::Message.new(-1, -1, '/__flush', nil)]
    end

    r = []
    @subscriptions.each do |k,v|
      next if v.to_i < 0
      messages = @bus.backlog(k,v)
      messages.each do |msg|
        r << msg if allowed?(msg)
      end
    end
    # stats message for all newly subscribed
    status_message = nil
    @subscriptions.each do |k,v|
      if v.to_i == -1
        status_message ||= {}
        status_message[k] = @bus.last_id(k)
      end
    end
    r << MessageBus::Message.new(-1, -1, '/__status', status_message) if status_message

    r.map!{|msg| filter(msg)}.compact!
    r || []
  end

  protected


  # heavily optimised to avoid all uneeded allocations
  NEWLINE="\r\n".freeze
  COLON_SPACE = ": ".freeze
  HTTP_11 = "HTTP/1.1 200 OK\r\n".freeze
  CONTENT_LENGTH = "Content-Length: ".freeze
  CONNECTION_CLOSE = "Connection: close\r\n".freeze

  def write_and_close(data)
    if @io
      @io.write(HTTP_11)
      @headers.each do |k,v|
        @io.write(k)
        @io.write(COLON_SPACE)
        @io.write(v)
        @io.write(NEWLINE)
      end
      @io.write(CONTENT_LENGTH)
      @io.write(data.bytes.to_a.length)
      @io.write(NEWLINE)
      @io.write(CONNECTION_CLOSE)
      @io.write(NEWLINE)
      @io.write(data)
      @io.close
      @io = nil
    else
      @async_response << data
      @async_response.done
      @async_response = nil
    end
  end

  def messages_to_json(msgs)
    MessageBus::Rack::Middleware.backlog_to_json(msgs)
  end
end
