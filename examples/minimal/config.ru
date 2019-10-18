# frozen_string_literal: true
require 'message_bus'

# MessageBus.long_polling_interval = 1000 * 2

use MessageBus::Rack::Middleware
run lambda { |_env| [200, { "Content-Type" => "text/html" }, ["Howdy"]] }
