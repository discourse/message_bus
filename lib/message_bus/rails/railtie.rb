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
    begin
      app.middleware.insert_before(ActionDispatch::Flash, MessageBus::Rack::Middleware)
    rescue
      app.middleware.use(MessageBus::Rack::Middleware)
    end

    MessageBus.logger = Rails.logger
  end
end
