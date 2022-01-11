# frozen_string_literal: true

$: << File.dirname(__FILE__)
$: << File.join(File.dirname(__FILE__), '..', 'lib')
require 'thin'
require 'lib/fake_async_middleware'
require 'message_bus'

require 'minitest/autorun'
require 'minitest/global_expectations'

require_relative "helpers"

CURRENT_BACKEND = (ENV['MESSAGE_BUS_BACKEND'] || :redis).to_sym

require "message_bus/backends/#{CURRENT_BACKEND}"
BACKEND_CLASS = MessageBus::BACKENDS.fetch(CURRENT_BACKEND)

puts "Running with backend: #{CURRENT_BACKEND}"

def test_only(*backends)
  skip "Test doesn't apply to #{CURRENT_BACKEND}" unless backends.include?(CURRENT_BACKEND)
end

def test_never(*backends)
  skip "Test doesn't apply to #{CURRENT_BACKEND}" if backends.include?(CURRENT_BACKEND)
end
