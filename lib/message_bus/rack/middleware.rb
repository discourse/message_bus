# frozen_string_literal: true

require 'json'

# our little message bus, accepts long polling and polling
module MessageBus::Rack; end

# Accepts requests from subscribers, validates and authenticates them,
# delivers existing messages from the backlog and informs a
# `MessageBus::ConnectionManager` of a connection which is remaining open.
class MessageBus::Rack::Middleware
  # @param [Array<MessageBus::Message>] backlog a list of messages for delivery
  # @return [JSON] a JSON representation of the backlog, compliant with the
  #   subscriber API specification
  def self.backlog_to_json(backlog)
    m = backlog.map do |msg|
      {
        global_id: msg.global_id,
        message_id: msg.message_id,
        channel: msg.channel,
        data: msg.data
      }
    end.to_a
    JSON.dump(m)
  end

  # @return [Boolean] whether the message listener (subscriber) is started or not)
  attr_reader :started_listener

  # Sets up the middleware to receive subscriber client requests and begins
  # listening for messages published on the bus for re-distribution (unless
  # the bus is disabled).
  #
  # @param [Proc] app the rack app
  # @param [Hash] config
  # @option config [MessageBus::Instance] :message_bus (`MessageBus`) a specific instance of message_bus
  def initialize(app, config = {})
    @app = app
    @bus = config[:message_bus] || MessageBus
    @connection_manager = MessageBus::ConnectionManager.new(@bus)
    @started_listener = false
    @base_route = "#{@bus.base_route}message-bus/"
    @base_route_length = @base_route.length
    @broadcast_route = "#{@base_route}broadcast"
    start_listener unless @bus.off?
  end

  # Stops listening for messages on the bus
  # @return [void]
  def stop_listener
    if @subscription
      @bus.unsubscribe(&@subscription)
      @started_listener = false
    end
  end

  # Process an HTTP request from a subscriber client
  # @param [Rack::Request::Env] env the request environment
  def call(env)
    return @app.call(env) unless env['PATH_INFO'].start_with? @base_route

    handle_request(env)
  end

  private

  def handle_request(env)
    # Prevent simple polling from clobbering the session
    # See: https://github.com/discourse/message_bus/issues/257
    if (rack_session_options = env[Rack::RACK_SESSION_OPTIONS])
      rack_session_options[:skip] = true
    end

    # special debug/test route
    if @bus.allow_broadcast? && env['PATH_INFO'] == @broadcast_route
      parsed = Rack::Request.new(env)
      @bus.publish parsed["channel"], parsed["data"]
      return [200, { "Content-Type" => "text/html" }, ["sent"]]
    end

    client_id = env['PATH_INFO'][@base_route_length..-1].split("/")[0]
    return [404, {}, ["not found"]] unless client_id

    headers = {}
    headers["Cache-Control"] = "must-revalidate, private, max-age=0"
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Pragma"] = "no-cache"
    headers["Expires"] = "0"

    if @bus.extra_response_headers_lookup
      @bus.extra_response_headers_lookup.call(env).each do |k, v|
        headers[k] = v
      end
    end

    if env["REQUEST_METHOD"] == "OPTIONS"
      return [200, headers, ["OK"]]
    end

    user_id = @bus.user_id_lookup.call(env) if @bus.user_id_lookup
    group_ids = @bus.group_ids_lookup.call(env) if @bus.group_ids_lookup
    site_id = @bus.site_id_lookup.call(env) if @bus.site_id_lookup

    # close db connection as early as possible
    close_db_connection!

    client = MessageBus::Client.new(
      client_id: client_id,
      user_id: user_id,
      site_id: site_id,
      group_ids: group_ids,
      message_bus: @bus,
      client_message_filters: compute_message_filters(env)
    )

    if channels = env['message_bus.channels']
      if seq = env['message_bus.seq']
        client.seq = seq.to_i
      end
      channels.each do |k, v|
        client.subscribe(k, v)
      end
    else
      request = Rack::Request.new(env)
      is_json = request.content_type && request.content_type.include?('application/json')
      data = is_json ? JSON.parse(request.body.read) : request.POST
      data.each do |k, v|
        if k == "__seq"
          client.seq = v.to_i
        else
          client.subscribe(k, v)
        end
      end
    end

    long_polling = @bus.long_polling_enabled? &&
                   env['QUERY_STRING'] !~ /dlp=t/ &&
                   @connection_manager.client_count < @bus.max_active_clients

    allow_chunked = env['HTTP_VERSION'] == 'HTTP/1.1'
    allow_chunked &&= !env['HTTP_DONT_CHUNK']
    allow_chunked &&= @bus.chunked_encoding_enabled?

    client.use_chunked = allow_chunked

    backlog = client.backlog

    if backlog.length > 0 && !allow_chunked
      client.close
      @bus.logger.debug "Delivering backlog #{backlog} to client #{client_id} for user #{user_id}"
      [200, headers, [self.class.backlog_to_json(backlog)]]
    elsif long_polling && env['rack.hijack'] && @bus.rack_hijack_enabled?
      io = env['rack.hijack'].call
      # TODO disable client till deliver backlog is called
      client.io = io
      client.headers = headers
      client.synchronize do
        client.deliver_backlog(backlog)
        add_client_with_timeout(client)
        client.ensure_first_chunk_sent
      end
      [418, {}, ["I'm a teapot, undefined in spec"]]
    elsif long_polling && env['async.callback']
      response = nil
      # load extension if needed
      begin
        response = Thin::AsyncResponse.new(env)
      rescue NameError
        require 'message_bus/rack/thin_ext'
        response = Thin::AsyncResponse.new(env)
      end

      headers.each do |k, v|
        response.headers[k] = v
      end

      if allow_chunked
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Transfer-Encoding"] = "chunked"
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
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
      [200, headers, [self.class.backlog_to_json(backlog)]]
    end
  rescue => e
    if @bus.on_middleware_error && result = @bus.on_middleware_error.call(env, e)
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

    client.cleanup_timer = @bus.timer.queue(@bus.long_polling_interval.to_f / 1000) {
      begin
        client.close
        @connection_manager.remove_client(client)
      rescue
        @bus.logger.warn "Failed to clean up client properly: #{$!} #{$!.backtrace}"
      end
    }
  end

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
          @bus.timer.queue(&run)
        end

        @started_listener = true
      end
    end
  end

  # @param query_string [String]
  # @return [String]
  def query_params(query_string)
    Rack::Utils.default_query_parser.parse_nested_query(query_string, '&')
  end

  # @param env [Hash]
  # @return [Array<Array<String, Proc>>]
  def compute_message_filters(env)
    @bus.client_message_filters.map do |channel_name, filter|
      [channel_name, filter.curry(2).call(query_params(env['QUERY_STRING']))]
    end
  end
end
