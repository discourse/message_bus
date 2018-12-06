# frozen_string_literal: true

module MessageBus::Rack; end

# Accepts requests from clients interested in using diagnostics functionality
# @see MessageBus::Diagnostics
class MessageBus::Rack::Diagnostics
  # @param [Proc] app the rack app
  # @param [Hash] config
  # @option config [MessageBus::Instance] :message_bus (`MessageBus`) a specific instance of message_bus
  def initialize(app, config = {})
    @app = app
    @bus = config[:message_bus] || MessageBus
  end

  # Process an HTTP request from a subscriber client
  # @param [Rack::Request::Env] env the request environment
  def call(env)
    return @app.call(env) unless env['PATH_INFO'].start_with? '/message-bus/_diagnostics'

    route = env['PATH_INFO'].split('/message-bus/_diagnostics')[1]

    if @bus.is_admin_lookup.nil? || !@bus.is_admin_lookup.call(env)
      return [403, {}, ['not allowed']]
    end

    return index unless route

    if route == '/discover'
      user_id = @bus.user_id_lookup.call(env)
      @bus.publish('/_diagnostics/discover', user_id: user_id)
      return [200, {}, ['ok']]
    end

    if route =~ /^\/hup\//
      hostname, pid = route.split('/hup/')[1].split('/')
      @bus.publish('/_diagnostics/hup', hostname: hostname, pid: pid.to_i)
      return [200, {}, ['ok']]
    end

    asset = route.split('/assets/')[1]
    if asset && !asset !~ /\//
      content = asset_contents(asset)
      split = asset.split('.')
      return [200, { 'Content-Type' => 'application/javascript;charset=UTF-8' }, [content]]
    end

    return [404, {}, ['not found']]
  end

  private

  def js_asset(name, type = "text/javascript")
    return generate_script_tag(name, type) unless @bus.cache_assets

    @@asset_cache ||= {}
    @@asset_cache[name] ||= generate_script_tag(name, type)
    @@asset_cache[name]
  end

  def generate_script_tag(name, type)
    "<script src='/message-bus/_diagnostics/assets/#{name}?#{file_hash(name)}' type='#{type}'></script>"
  end

  def file_hash(asset)
    require 'digest/sha1'
    Digest::SHA1.hexdigest(asset_contents(asset))
  end

  def asset_contents(asset)
    File.open(asset_path(asset)).read
  end

  def asset_path(asset)
    File.expand_path("../../../../assets/#{asset}", __FILE__)
  end

  def index
    html = <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
        </head>
        <body>
          <div id="app"></div>
          #{js_asset "jquery-1.8.2.js"}
          #{js_asset "react.js"}
          #{js_asset "react-dom.js"}
          #{js_asset "babel.min.js"}
          #{js_asset "message-bus.js"}
          #{js_asset "application.jsx", "text/jsx"}
        </body>
      </html>
    HTML
    return [200, { "content-type" => "text/html;" }, [html]]
  end
end
