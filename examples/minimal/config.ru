require 'message_bus'
require 'message_bus/rack/middleware'

# MessageBus.long_polling_interval = 1000 * 2

use MessageBus::Rack::Middleware
run lambda { |_env| [200, { "Content-Type" => "text/html" }, ["Howdy"]] }
