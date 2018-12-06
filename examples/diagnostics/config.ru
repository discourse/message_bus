require 'message_bus'

MessageBus.configure(backend: :redis, url: ENV['REDISURL'])
MessageBus.enable_diagnostics

MessageBus.user_id_lookup do |_env|
  1
end

MessageBus.is_admin_lookup do |_env|
  true
end

use MessageBus::Rack::Middleware
run lambda { |_env|
  [
    200,
    { "Content-Type" => "text/html" },
    ['Howdy. Check out <a href="/message-bus/_diagnostics">the diagnostics UI</a>.']
  ]
}
