# frozen_string_literal: true

module MessageBus; module Rails; end; end

# rails engine for asset pipeline
class MessageBus::Rails::Engine < ::Rails::Engine; end

class MessageBus::Rails::Railtie < ::Rails::Railtie
  generators do
    require 'message_bus/rails/generators/migrations/message_bus_migration_generator'
  end

  initializer "message_bus.configure_init" do |app|
    # We want MessageBus to show up after the session middleware, but depending on how
    # the Rails app is configured that might be ActionDispatch::Session::CookieStore, or potentially
    # ActionDispatch::Session::ActiveRecordStore.
    #
    # given https://github.com/rails/rails/commit/fedde239dcee256b417dc9bcfe5fef603bf0d952#diff-533a9a9cc17a8a899cb830626089e5f9
    # there is no way of walking the stack for operations
    if !skip_middleware?(app.config)
      if api_only?(app.config)
        app.middleware.use(MessageBus::Rack::Middleware)
      else
        app.middleware.insert_before(ActionDispatch::Flash, MessageBus::Rack::Middleware)
      end
    end

    MessageBus.logger = Rails.logger
  end

  def skip_middleware?(config)
    return false if !config.respond_to?(:skip_message_bus_middleware)

    config.skip_message_bus_middleware
  end

  def api_only?(config)
    return false if !config.respond_to?(:api_only)

    config.api_only
  end
end
