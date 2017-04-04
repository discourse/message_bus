require 'json'

# our little message bus, accepts long polling and polling
module MessageBus::Rack; end

class MessageBus::Rack::Middleware

  def start_listener
    unless @started_listener

      thin = defined?(Thin::Server) && ObjectSpace.each_object(Thin::Server).to_a.first
      thin_running = thin && thin.running?

      @subscription = @bus.subscribe do |msg|
        run = proc do
          begin
            @connection_manager.notify_clients(msg) if @connection_manager
          rescue
            @bus.logger.warn "Failed to notify clients: #{$!} #{$!.backtrace}"
          end
        end

        if thin_running
          EM.next_tick(&run)
        else
          MessageBus.timer.queue(&run)
        end

        @started_listener = true
      end
    end
  end

  def initialize(app, config = {})
    @app = app
    @bus = config[:message_bus] || MessageBus
    @connection_manager = MessageBus::ConnectionManager.new(@bus)
    self.start_listener
  end

  def stop_listener
    if @subscription
      @bus.unsubscribe(&@subscription)
      @started_listener = false
    end
  end

  def self.backlog_to_json(backlog)
    m = backlog.map do |msg|
      {
        :global_id => msg.global_id,
        :message_id => msg.message_id,
        :channel => msg.channel,
        :data => msg.data
      }
    end.to_a
    JSON.dump(m)
  end
  # GC helping.
  PATH_INFO = 'PATH_INFO'.freeze
  CONTENT_TYPE = 'Content-Type'.freeze
  SLASH = '/'.freeze
  BUS_REGEX = /^\/message-bus\//.freeze
  USE_MATCH = BUS_REGEX.respond_to?(:match?)
  BROADCAST = '/message-bus/broadcast'.freeze
  DIAGNOSTICS = '/message-bus/_diagnostics'.freeze
  CHANNEL = 'channel'.freeze
  DATA = 'data'.freeze
  TEXT_HTML = 'text/html'.freeze
  SENT = 'sent'.freeze
  NOT_FOUND = 'not found'.freeze
  MESSAGE_BUS_CHANNEL = 'message_bus.channels'.freeze
  MESSAGE_BUS_SEQ = 'message_bus.seq'.freeze
  APPLICATION_JSON = 'application/json'.freeze
  SEQ = '__seq'.freeze
  CACHE_CONTROL='Cache-Control'.freeze
  CACHE_LINE = 'must-revalidate, private, max-age=0'.freeze
  CONTENT_TYPE_LINE = 'application/json; charset=utf-8'.freeze
  PRAGMA = 'Pragma'.freeze
  NO_CACHE= 'no-cache'.freeze
  EXPIRES= 'Expires'.freeze
  ZERO = '0'.freeze
  REQUEST_METHOD = 'REQUEST_METHOD'.freeze
  OPTIONS = 'OPTIONS'.freeze
  OK='OK'.freeze
  QUERY_STRING='QUERY_STRING'.freeze
  DLP_REGEX=/dlp=t/.freeze
  HTTP_1_1= 'HTTP/1.1'.freeze
  HTTP_VERSION='HTTP_VERSION'.freeze
  HTTP_CHUNK = 'HTTP_DONT_CHUNK'.freeze
  RACK_HIJACK = 'rack.hijack'.freeze
  IM_A_TEAPOT = "I'm a teapot, undefined in spec".freeze 
  ASYNC_CALLBACK = 'async.callback'.freeze
  X_CONTENT_TYPE_OPTIONS = 'X-Content-Type-Options'.freeze
  NO_SNIFF = 'nosniff'.freeze
  TRANSFER_ENCODING = 'Transfer-Encoding'.freeze
  CHUNKED = 'chunked'.freeze
  TEXT_CONTENT_TYPE_LINE = 'text/plain; charset=utf-8'.freeze
  EMPTY_LIST = "[]".freeze
  
  def call(env)

    return @app.call(env) unless USE_MATCH ? BUS_REGEX.match?(env[PATH_INFO]) : env[PATH_INFO] =~ BUS_REGEX

    # special debug/test route
    if @bus.allow_broadcast? && env[PATH_INFO] == BROADCAST
        parsed = Rack::Request.new(env)
        @bus.publish parsed[CHANNEL], parsed[DATA]
        return [200,{CONTENT_TYPE => TEXT_HTML},[SENT]]
    end

    if env[PATH_INFO].start_with? DIAGNOSTICS
      diags = MessageBus::Rack::Diagnostics.new(@app, message_bus: @bus)
      return diags.call(env)
    end

    client_id = env[PATH_INFO].split(SLASH)[2]
    return [404, {}, [NOT_FOUND]] unless client_id

    user_id = @bus.user_id_lookup.call(env) if @bus.user_id_lookup
    group_ids = @bus.group_ids_lookup.call(env) if @bus.group_ids_lookup
    site_id = @bus.site_id_lookup.call(env) if @bus.site_id_lookup

    # close db connection as early as possible
    close_db_connection!

    client = MessageBus::Client.new(message_bus: @bus, client_id: client_id,
                                    user_id: user_id, site_id: site_id, group_ids: group_ids)

    if channels = env[MESSAGE_BUS_CHANNEL]
      if seq = env[MESSAGE_BUS_SEQ]
        client.seq = seq.to_i
      end
      channels.each do |k, v|
        client.subscribe(k, v)
      end
    else
      request = Rack::Request.new(env)
      is_json = request.content_type && request.content_type.include?(APPLICATION_JSON)
      data = is_json ? JSON.parse(request.body.read) : request.POST
      data.each do |k,v|
        if k == SEQ
          client.seq = v.to_i
        else
          client.subscribe(k, v)
        end
      end
    end

    headers = {}
    headers[CACHE_CONTROL] = CACHE_LINE
    headers[CONTENT_TYPE] = CONTENT_TYPE_LINE
    headers[PRAGMA] = NO_CACHE
    headers[EXPIRES] = ZERO

    if @bus.extra_response_headers_lookup
      @bus.extra_response_headers_lookup.call(env).each do |k,v|
        headers[k] = v
      end
    end

    if env[REQUEST_METHOD] == OPTIONS
      return [200, headers, [OK]]
    end

    long_polling = @bus.long_polling_enabled? &&
                   (USE_MATCH ? !DLP_REGEX.match?(env[QUERY_STRING]) : env[QUERY_STRING] !~ DLP_REGEX) &&
                   @connection_manager.client_count < @bus.max_active_clients

    allow_chunked = env[HTTP_VERSION] == HTTP_1_1
    allow_chunked &&= !env[HTTP_CHUNK]
    allow_chunked &&= @bus.chunked_encoding_enabled?

    client.use_chunked = allow_chunked

    backlog = client.backlog

    if backlog.length > 0 && !allow_chunked
      client.cancel
      @bus.logger.debug "Delivering backlog #{backlog} to client #{client_id} for user #{user_id}"
      [200, headers, [self.class.backlog_to_json(backlog)] ]
    elsif long_polling && env[RACK_HIJACK] && @bus.rack_hijack_enabled?
      io = env['rack.hijack'].call
      # TODO disable client till deliver backlog is called
      client.io = io
      client.headers = headers
      client.synchronize do
        client.deliver_backlog(backlog)
        add_client_with_timeout(client)
        client.ensure_first_chunk_sent
      end
      [418, {}, [IM_A_TEAPOT]]
    elsif long_polling && env[ASYNC_CALLBACK]
      response = nil
      # load extension if needed
      begin
        response = Thin::AsyncResponse.new(env)
      rescue NameError
        require 'message_bus/rack/thin_ext'
        response = Thin::AsyncResponse.new(env)
      end

      headers.each do |k,v|
        response.headers[k] = v
      end

      if allow_chunked
        response.headers[X_CONTENT_TYPE_OPTIONS] = NO_SNIFF
        response.headers[TRANSFER_ENCODING] = CHUNKED
        response.headers[CONTENT_TYPE] = TEXT_CONTENT_TYPE_LINE
      end

      response.status = 200
      client.async_response = response
      client.synchronize do
        add_client_with_timeout(client)
        client.deliver_backlog(backlog)
        client.ensure_first_chunk_sent
      end

      throw :async
    else
      [200, headers, [EMPTY_LIST]]
    end

  rescue => e
    if @bus.on_middleware_error && result=@bus.on_middleware_error.call(env, e)
      result
    else
      raise
    end
  end

  def close_db_connection!
    # IMPORTANT
    # ConnectionManagement in Rails puts a BodyProxy around stuff
    #  this means connections are not returned until rack.async is
    #  closed
    if defined? ActiveRecord::Base.clear_active_connections!
      ActiveRecord::Base.clear_active_connections!
    end
  end

  def add_client_with_timeout(client)
    @connection_manager.add_client(client)

    client.cleanup_timer = MessageBus.timer.queue( @bus.long_polling_interval.to_f / 1000) {
      begin
        client.cleanup_timer = nil
        client.ensure_closed!
        @connection_manager.remove_client(client)
      rescue
        @bus.logger.warn "Failed to clean up client properly: #{$!} #{$!.backtrace}"
      end
    }
  end
end
