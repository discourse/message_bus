require 'message_bus'
require 'rack-mini-profiler'

Rack::MiniProfiler.config.storage = Rack::MiniProfiler::MemoryStore

use Rack::MiniProfiler
use MessageBus::Rack::Middleware
run lambda { |env| [200, {"Content-Type" => "text/html"}, ["Howdy"]]  }
