# frozen_string_literal: true

# Represents a connected subscriber and delivers published messages over its
# connected socket.
class MessageBus::Client
  # @return [String] the unique ID provided by the client
  attr_accessor :client_id
  # @return [String,Integer] the user ID the client was authenticated for
  attr_accessor :user_id
  # @return [Array<String,Integer>] the group IDs the authenticated client is a member of
  attr_accessor :group_ids
  # @return [Time] the time at which the client connected
  attr_accessor :connect_time
  # @return [String] the site ID the client was authenticated for; used for hosting multiple
  attr_accessor :site_id
  # @return [MessageBus::TimerThread::Cancelable] a timer job that is used to
  #   auto-disconnect the client at the configured long-polling interval
  attr_accessor :cleanup_timer
  # @return [Thin::AsyncResponse, nil]
  attr_accessor :async_response
  # @return [IO] the HTTP socket the client is connected on
  attr_accessor :io
  # @return [Hash<String => String>] custom headers to include in HTTP responses
  attr_accessor :headers
  # @return [Integer] the connection sequence number the client provided when connecting
  attr_accessor :seq
  # @return [Boolean] whether or not the client should use chunked encoding
  attr_accessor :use_chunked
  # @return [Array<Array<String, Proc>>] :client_message_filters a set of channels and procs to determine whether
  #  a message should be delivered to the client
  attr_reader :client_message_filters

  # @param [Hash] opts
  # @option opts [String] :client_id the unique ID provided by the client
  # @option opts [String,Integer] :user_id (`nil`) the user ID the client was authenticated for
  # @option opts [Array<String,Integer>] :group_ids (`[]`) the group IDs the authenticated client is a member of
  # @option opts [String] :site_id (`nil`) the site ID the client was authenticated for; used for hosting multiple
  #   applications or instances of an application against a single message_bus
  # @option opts [#to_i] :seq (`0`) the connection sequence number the client provided when connecting
  # @option opts [MessageBus::Instance] :message_bus (`MessageBus`) a specific instance of message_bus
  # @option opts [Array<Array<String, Proc>>] :client_message_filters a set of channels and procs to determine whether
  #   a message should be delivered to the client
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
    @async_response = nil
    @io = nil
    @wrote_headers = false
    @client_message_filters = opts[:client_message_filters]
  end

  # @yield executed with a lock on the Client instance
  # @return [void]
  def synchronize
    @lock.synchronize { yield }
  end

  # Closes the client connection
  def close
    if cleanup_timer
      # concurrency may nil cleanup timer
      cleanup_timer.cancel rescue nil
      self.cleanup_timer = nil
    end
    ensure_closed!
  end

  # Delivers a backlog of messages to the client, if there is anything in it.
  # If chunked encoding/streaming is in use, will keep the connection open;
  # if not, will close it.
  #
  # @param [Array<MessageBus::Message>] backlog the set of messages to deliver
  # @return [void]
  def deliver_backlog(backlog)
    if backlog.length > 0
      if use_chunked
        write_chunk(messages_to_json(backlog))
      else
        write_and_close messages_to_json(backlog)
      end
    end
  end

  # If no data has yet been sent to the client, sends an empty chunk; prevents
  # clients from entering a timeout state if nothing is delivered initially.
  def ensure_first_chunk_sent
    if use_chunked && @chunks_sent == 0
      write_chunk("[]")
    end
  end

  # @return [Boolean] whether the connection is closed or not
  def closed?
    !@async_response && !@io
  end

  # Subscribes the client to messages on a channel, optionally from a
  # defined starting point.
  #
  # @param [String] channel the channel to subscribe to
  # @param [Integer, nil] last_seen_id the ID of the last message the client
  #   received. If nil, will be subscribed from the head of the backlog.
  # @return [void]
  def subscribe(channel, last_seen_id)
    last_seen_id = nil if last_seen_id == ""
    last_seen_id ||= @bus.last_id(channel)
    @subscriptions[channel] = last_seen_id.to_i
  end

  # @return [Hash<String => Integer>] the active subscriptions, mapping channel
  #   names to last seen message IDs
  def subscriptions
    @subscriptions
  end

  # Delivers a message to the client, even if it's empty
  # @param [MessageBus::Message, nil] msg the message to deliver
  # @return [void]
  def <<(msg)
    json = messages_to_json([msg])
    if use_chunked
      write_chunk json
    else
      write_and_close json
    end
  end

  # @param [MessageBus::Message] msg the message in question
  # @return [Boolean] whether or not the client has permission to receive the
  #   passed message
  def allowed?(msg)
    client_allowed = !msg.client_ids || msg.client_ids.length == 0 || msg.client_ids.include?(self.client_id)

    user_allowed = false
    group_allowed = false

    has_users = msg.user_ids && msg.user_ids.length > 0
    has_groups = msg.group_ids && msg.group_ids.length > 0

    if has_users
      user_allowed = msg.user_ids.include?(self.user_id)
    end

    if has_groups
      group_allowed = (
        msg.group_ids - (self.group_ids || [])
      ).length < msg.group_ids.length
    end

    has_permission = client_allowed && (user_allowed || group_allowed || (!has_users && !has_groups))

    return has_permission if !has_permission

    client_message_filters.each.with_object(true) do |(channel_prefix, filter_proc), _|
      next unless msg.channel.start_with?(channel_prefix)

      break false unless filter_proc.call(msg)
    end
  end

  # @return [Array<MessageBus::Message>] the set of messages the client is due
  #   to receive, based on its subscriptions and permissions. Includes status
  #   message if any channels have no messages available and the client
  #   requested a message newer than the newest on the channel, or when there
  #   are messages available that the client doesn't have permission for.
  def backlog
    r = []
    new_message_ids = nil

    last_bus_ids = @bus.last_ids(*@subscriptions.keys, site_id: site_id)

    @subscriptions.each do |k, v|
      last_client_id = v.to_i
      last_bus_id = last_bus_ids[k]

      if last_client_id < -1 # Client requesting backlog relative to bus position
        last_client_id = last_bus_id + last_client_id + 1
        last_client_id = 0 if last_client_id < 0
      elsif last_client_id == -1 # Client not requesting backlog
        next
      elsif last_client_id == last_bus_id # Client already up-to-date
        next
      elsif last_client_id > last_bus_id # Client ahead of the bus
        @subscriptions[k] = -1
        next
      end

      messages = @bus.backlog(k, last_client_id, site_id)

      messages.each do |msg|
        if allowed?(msg)
          r << msg
        else
          new_message_ids ||= {}
          new_message_ids[k] = msg.message_id
        end
      end
    end

    # stats message for all newly subscribed
    status_message = nil
    @subscriptions.each do |k, v|
      if v.to_i == -1 || (new_message_ids && new_message_ids[k])
        status_message ||= {}
        @subscriptions[k] = status_message[k] = last_bus_ids[k]
      end
    end

    r << MessageBus::Message.new(-1, -1, '/__status', status_message) if status_message

    r || []
  end

  private

  # heavily optimised to avoid all unneeded allocations
  NEWLINE = "\r\n".freeze
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
    @headers.each do |k, v|
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

    # chunked encoding may be "re-chunked" by proxies, so add a separator
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
    elsif @io
      @io.write(chunk_length.to_s(16) << NEWLINE << data << postfix << NEWLINE)
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

  def ensure_closed!
    return unless in_async?

    if use_chunked
      write_chunk("[]")
      if @io
        @io.write("0\r\n\r\n")
        @io.close
        @io = nil
      end
      if @async_response
        @async_response << ("0\r\n\r\n")
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

  def messages_to_json(msgs)
    MessageBus::Rack::Middleware.backlog_to_json(msgs)
  end

  def in_async?
    @async_response || @io
  end
end
