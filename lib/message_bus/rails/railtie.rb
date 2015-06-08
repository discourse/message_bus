module MessageBus; module Rails; end; end

# rails engine for asset pipeline
class MessageBus::Rails::Engine < ::Rails::Engine; end

class MessageBus::Rails::Railtie < ::Rails::Railtie
  initializer "message_bus.configure_init" do |app|
    MessageBus::MessageHandler.load_handlers("#{Rails.root}/app/message_handlers")

    # We want MessageBus to show up after the session middleware, but depending on how
    # the Rails app is configured that might be ActionDispatch::Session::CookieStore, or potentially
    # ActionDispatch::Session::ActiveRecordStore.
    #
    # To handle either case, we insert it at the end of the middleware stack.
    #
    app.middleware.use(MessageBus::Rack::Middleware)
    MessageBus.logger = Rails.logger
  end
end
