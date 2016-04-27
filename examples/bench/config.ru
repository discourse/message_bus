$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'message_bus'
require 'stackprof'

if defined?(PhusionPassenger)
    PhusionPassenger.on_event(:starting_worker_process) do |forked|
        if forked
            # We're in smart spawning mode.
            MessageBus.after_fork
        else
            # We're in conservative spawning mode. We don't need to do anything.
        end
    end
end


# require 'rack-mini-profiler'

# Rack::MiniProfiler.config.storage = Rack::MiniProfiler::MemoryStore

# use Rack::MiniProfiler
# StackProf.start(mode: :cpu)
# Thread.new {
#   sleep 10
#   StackProf.stop
#   File.write("test.prof",Marshal.dump(StackProf.results))
# }

MessageBus.long_polling_interval = 1000 * 2
MessageBus.max_active_clients = 10000
use MessageBus::Rack::Middleware
run lambda { |env| [200, {"Content-Type" => "text/html"}, ["Howdy"]]  }
