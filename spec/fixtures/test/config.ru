require 'message_bus'

MessageBus.config[:backend] = :memory
MessageBus.long_polling_interval = 1000
use MessageBus::Rack::Middleware

run ->(env) do
  if env["REQUEST_METHOD"] == "GET" && env["REQUEST_PATH"] == "/publish"
    payload = { hello: "world" }

    ["/test", "/test2"].each do |channel|
      MessageBus.publish(channel, payload)
    end
  end

  [200, { "Content-Type" => "text/html" }, ["Howdy"]]
end
