require 'message_bus'

#MessageBus.long_polling_interval = 1000 * 2

use MessageBus::Rack::Middleware
run lambda { |env| [200, {"Content-Type" => "text/html"}, ["Howdy"]]  }

