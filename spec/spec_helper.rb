$: << File.dirname(__FILE__)
$: << File.join(File.dirname(__FILE__), '..', 'lib')
require 'thin'
require 'lib/fake_async_middleware'
require 'logger'
require 'message_bus'

require 'minitest/autorun'
require 'minitest/spec'

backend = (ENV['MESSAGE_BUS_BACKEND'] || :redis).to_sym
MESSAGE_BUS_CONFIG = { backend: backend, logger: Logger.new(STDOUT) }
require "message_bus/backends/#{backend}"
PUB_SUB_CLASS = MessageBus::BACKENDS.fetch(backend)
case backend
when :redis, :redis_streams
  MESSAGE_BUS_CONFIG.merge!(url: ENV['REDISURL'])
when :postgres
  MESSAGE_BUS_CONFIG.merge!(backend_options: { host: ENV['PGHOST'], user: ENV['PGUSER'] || ENV['USER'], password: ENV['PGPASSWORD'], dbname: ENV['PGDATABASE'] || 'message_bus_test' })
end
puts "Running with backend: #{backend}"

def wait_for(timeout_milliseconds = 2000)
  timeout = (timeout_milliseconds + 0.0) / 1000
  finish = Time.now + timeout

  Thread.new do
    while Time.now < finish && !yield
      sleep(0.001)
    end
  end.join
end

def test_only(*backends)
  backend = MESSAGE_BUS_CONFIG[:backend]
  skip "Test doesn't apply to #{backend}" unless backends.include?(backend)
end

def test_never(*backends)
  backend = MESSAGE_BUS_CONFIG[:backend]
  skip "Test doesn't apply to #{backend}" if backends.include?(backend)
end
