# frozen_string_literal: true

module MessageBus; module Rails; end; end

# rails engine for asset pipeline
class MessageBus::Rails::Engine < ::Rails::Engine; end

class MessageBus::Rails::Railtie < ::Rails::Railtie
  initializer "message_bus.configure_init" do |app|
    # We want MessageBus to show up after the session middleware, but depending on how
    # the Rails app is configured that might be ActionDispatch::Session::CookieStore, or potentially
    # ActionDispatch::Session::ActiveRecordStore.
    #
    # To handle either case, we insert it before ActionDispatch::Flash.
    #
    # For APIs or apps that have ActionDispatch::Flash deleted from the middleware
    # stack we just push MessageBus to the bottom.
    if api_only?(app.config) || flash_middleware_deleted?(app.middleware)
      app.middleware.use(MessageBus::Rack::Middleware)
    else
      app.middleware.insert_before(ActionDispatch::Flash, MessageBus::Rack::Middleware)
    end

    MessageBus.logger = Rails.logger
  end

  def api_only?(config)
    return false unless config.respond_to?(:api_only)

    config.api_only
  end

  def flash_middleware_deleted?(middleware)
    ops = middleware.instance_variable_get(:@operations)
    ops.any? { |m| m[0] == :delete && m[1].include?(ActionDispatch::Flash) }
  end
end
