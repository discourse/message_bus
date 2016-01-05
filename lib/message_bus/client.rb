class MessageBus::Client
  attr_accessor :client_id, :user_id, :group_ids, :connect_time,
                :subscribed_sets, :site_id, :cleanup_timer,
                :async_response, :io, :headers, :seq, :use_chunked

  def initialize(opts)
    self.client_id = opts[:client_id]
    self.user_id = opts[:user_id]
    self.group_ids = opts[:group_ids] || []
    self.site_id = opts[:site_id]
    self.seq = opts[:seq].to_i
    self.connect_time = Time.now
    @lock = Mutex.new
    @bus = opts[:message_bus] || MessageBus
    @subscriptions = {}
    @chunks_sent = 0
  end

  def synchronize
    @lock.synchronize { yield }
  end

  def cancel
    if cleanup_timer
      # concurrency may nil cleanup timer
      cleanup_timer.cancel rescue nil
      self.cleanup_timer = nil
    end
    ensure_closed!
  end

  def in_async?
    @async_response || @io
  end

  def deliver_backlog(backlog)
    if backlog.length > 0
      if use_chunked
        write_chunk(messages_to_json(backlog))
      else
        write_and_close messages_to_json(backlog)
      end
    end
  end

  def ensure_first_chunk_sent
    if use_chunked && @chunks_sent == 0
      write_chunk("[]".freeze)
    end
  end

  def ensure_closed!
    return unless in_async?
    if use_chunked
      write_chunk("[]".freeze)
      if @io
        @io.write("0\r\n\r\n".freeze)
        @io.close
        @io = nil
      end
      if @async_response
        @async_response << ("0\r\n\r\n".freeze)
        @async_response.done
        @async_response = nil
      end
    else
      write_and_close "[]"
    end
  rescue
    # we may have a dead socket, just nil the @io
    @io = nil
    @async_response = nil
  end

  def close
    ensure_closed!
  end

  def closed?
    !@async_response && !@io
  end

  def subscribe(channel, last_seen_id)
    last_seen_id = nil if last_seen_id == ""
    last_seen_id ||= @bus.last_id(channel)
    @subscriptions[channel] = last_seen_id.to_i
  end

  def subscriptions
    @subscriptions
  end

  def <<(msg)
    json = messages_to_json([msg])
    if use_chunked
      write_chunk json
    else
      write_and_close json
    end
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

  def backlog
    r = []
    @subscriptions.each do |k,v|
      next if v.to_i < 0
      messages = @bus.backlog(k, v, site_id)
      messages.each do |msg|
        r << msg if allowed?(msg)
      end
    end
    # stats message for all newly subscribed
    status_message = nil
    @subscriptions.each do |k,v|
      if v.to_i == -1
        status_message ||= {}
        @subscriptions[k] = status_message[k] = @bus.last_id(k, site_id)
      end
    end
    r << MessageBus::Message.new(-1, -1, '/__status', status_message) if status_message

    r || []
  end

  protected


  # heavily optimised to avoid all uneeded allocations
  NEWLINE="\r\n".freeze
  COLON_SPACE = ": ".freeze
  HTTP_11 = "HTTP/1.1 200 OK\r\n".freeze
  CONTENT_LENGTH = "Content-Length: ".freeze
  CONNECTION_CLOSE = "Connection: close\r\n".freeze
  CHUNKED_ENCODING = "Transfer-Encoding: chunked\r\n".freeze
  NO_SNIFF = "X-Content-Type-Options: nosniff\r\n".freeze

  TYPE_TEXT = "Content-Type: text/plain; charset=utf-8\r\n".freeze
  TYPE_JSON = "Content-Type: application/json; charset=utf-8\r\n".freeze

  def write_headers
    @io.write(HTTP_11)
    @headers.each do |k,v|
      next if k == "Content-Type"
      @io.write(k)
      @io.write(COLON_SPACE)
      @io.write(v)
      @io.write(NEWLINE)
    end
    @io.write(CONNECTION_CLOSE)
    if use_chunked
      @io.write(TYPE_TEXT)
    else
      @io.write(TYPE_JSON)
    end
  end

  def write_chunk(data)
    @bus.logger.debug "Delivering messages #{data} to client #{client_id} for user #{user_id} (chunked)"
    if @io && !@wrote_headers
      write_headers
      @io.write(CHUNKED_ENCODING)
      # this is required otherwise chrome will delay onprogress calls
      @io.write(NO_SNIFF)
      @io.write(NEWLINE)
      @wrote_headers = true
    end

    # chunked encoding may be "re-chunked" by proxies, so add a seperator
    postfix = NEWLINE + "|" + NEWLINE
    data = data.gsub(postfix, NEWLINE + "||" + NEWLINE)
    chunk_length = data.bytesize + postfix.bytesize

    @chunks_sent += 1

    if @async_response
      @async_response << chunk_length.to_s(16)
      @async_response << NEWLINE
      @async_response << data
      @async_response << postfix
      @async_response << NEWLINE
    else
      @io.write(chunk_length.to_s(16))
      @io.write(NEWLINE)
      @io.write(data)
      @io.write(postfix)
      @io.write(NEWLINE)
    end
  end

  def write_and_close(data)
    @bus.logger.debug "Delivering messages #{data} to client #{client_id} for user #{user_id}"
    if @io
      write_headers
      @io.write(CONTENT_LENGTH)
      @io.write(data.bytes.to_a.length)
      @io.write(NEWLINE)
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
