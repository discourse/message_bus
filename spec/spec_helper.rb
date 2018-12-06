$: << File.dirname(__FILE__)
$: << File.join(File.dirname(__FILE__), '..', 'lib')
require 'thin'
require 'lib/fake_async_middleware'
require 'message_bus'

require 'minitest/autorun'
require 'minitest/spec'

require_relative "helpers"

backend = (ENV['MESSAGE_BUS_BACKEND'] || :redis).to_sym
MESSAGE_BUS_CONFIG = test_config_for_backend(backend)
require "message_bus/backends/#{backend}"
PUB_SUB_CLASS = MessageBus::BACKENDS.fetch(backend)
puts "Running with backend: #{backend}"

def test_only(*backends)
  backend = MESSAGE_BUS_CONFIG[:backend]
  skip "Test doesn't apply to #{backend}" unless backends.include?(backend)
end

def test_never(*backends)
  backend = MESSAGE_BUS_CONFIG[:backend]
  skip "Test doesn't apply to #{backend}" if backends.include?(backend)
end
