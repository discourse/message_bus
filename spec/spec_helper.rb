$: << File.dirname(__FILE__)
$: << File.join(File.dirname(__FILE__), '..', 'lib')
require 'thin'
require 'lib/fake_async_middleware'
require 'message_bus'

require 'minitest/autorun'
require 'minitest/spec'

backend = (ENV['MESSAGE_BUS_BACKEND'] || :redis).to_sym
MESSAGE_BUS_CONFIG = {:backend=>backend}
require "message_bus/backends/#{backend}"
PUB_SUB_CLASS = MessageBus::BACKENDS.fetch(backend)
if backend == :postgres
  MESSAGE_BUS_CONFIG.merge!(:backend_options=>{:user=>ENV['PGUSER'] || ENV['USER'], :dbname=>ENV['PGDATABASE'] || 'message_bus_test'})
end
puts "Running with backend: #{backend}"

def wait_for(timeout_milliseconds)
  timeout = (timeout_milliseconds + 0.0) / 1000
  finish = Time.now + timeout

  Thread.new do
    while Time.now < finish && !yield
      sleep(0.001)
    end
  end.join

end
