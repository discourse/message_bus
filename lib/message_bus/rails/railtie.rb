module MessageBus; module Rails; end; end

# rails engine for asset pipeline
class MessageBus::Rails::Engine < ::Rails::Engine; end

class MessageBus::Rails::Railtie < ::Rails::Railtie
  initializer "message_bus.configure_init" do |app|
    MessageBus::MessageHandler.load_handlers("#{Rails.root}/app/message_handlers")
    app.middleware.insert_after(ActiveRecord::QueryCache, MessageBus::Rack::Middleware)
    MessageBus.logger = Rails.logger
  end
end
