# our little message bus, accepts long polling and polling
module MessageBus::Rack; end

class MessageBus::Rack::Middleware

  def start_listener
    unless @started_listener

      require 'eventmachine'
      require 'message_bus/em_ext'

      @subscription = @bus.subscribe do |msg|
        if EM.reactor_running?
          EM.next_tick do
            begin
              @connection_manager.notify_clients(msg) if @connection_manager
            rescue
              @bus.logger.warn "Failed to notify clients: #{$!} #{$!.backtrace}"
            end
          end
        end
      end
      @started_listener = true
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

  def call(env)

    return @app.call(env) unless env['PATH_INFO'] =~ /^\/message-bus\//

    # special debug/test route
    if @bus.allow_broadcast? && env['PATH_INFO'] == '/message-bus/broadcast'.freeze
        parsed = Rack::Request.new(env)
        @bus.publish parsed["channel".freeze], parsed["data".freeze]
        return [200,{"Content-Type".freeze => "text/html".freeze},["sent"]]
    end

    if env['PATH_INFO'].start_with? '/message-bus/_diagnostics'.freeze
      diags = MessageBus::Rack::Diagnostics.new(@app, message_bus: @bus)
      return diags.call(env)
    end

    client_id = env['PATH_INFO'].split("/")[2]
    return [404, {}, ["not found"]] unless client_id

    user_id = @bus.user_id_lookup.call(env) if @bus.user_id_lookup
    group_ids = @bus.group_ids_lookup.call(env) if @bus.group_ids_lookup
    site_id = @bus.site_id_lookup.call(env) if @bus.site_id_lookup

    # close db connection as early as possible
    close_db_connection!

    client = MessageBus::Client.new(message_bus: @bus, client_id: client_id, user_id: user_id, site_id: site_id, group_ids: group_ids)

    request = Rack::Request.new(env)
    request.POST.each do |k,v|
      client.subscribe(k, v)
    end

    backlog = client.backlog
    headers = {}
    headers["Cache-Control"] = "must-revalidate, private, max-age=0"
    headers["Content-Type"] ="application/json; charset=utf-8"
    headers["Access-Control-Allow-Origin"] = @bus.access_control_allow_origin if @bus.access_control_allow_origin

    ensure_reactor

    long_polling = @bus.long_polling_enabled? &&
                   env['QUERY_STRING'] !~ /dlp=t/.freeze &&
                   EM.reactor_running? &&
                   @connection_manager.client_count < @bus.max_active_clients

    if backlog.length > 0
      [200, headers, [self.class.backlog_to_json(backlog)] ]
    elsif long_polling && env['rack.hijack'] && @bus.rack_hijack_enabled?
      io = env['rack.hijack'].call
      client.io = io

      add_client_with_timeout(client)
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

      headers.each do |k,v|
        response.headers[k] = v
      end
      response.status = 200

      client.async_response = response

      add_client_with_timeout(client)

      throw :async
    else
      [200, headers, ["[]"]]
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

  def ensure_reactor
    # ensure reactor is running
    if EM.reactor_pid != Process.pid
      Thread.new { EM.run }
      i = 100
      while !EM.reactor_running? && i > 0
        sleep 0.001
        i -= 1
      end
    end
  end

  def add_client_with_timeout(client)
    @connection_manager.add_client(client)

    client.cleanup_timer = ::EM::Timer.new( @bus.long_polling_interval.to_f / 1000) {
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

