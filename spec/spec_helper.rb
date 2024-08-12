# frozen_string_literal: true

require 'thin'
require 'dotenv/load'
require_relative 'lib/fake_async_middleware'
require 'redis'
require 'pg'
require 'message_bus'

require 'minitest/autorun'
require 'minitest/global_expectations'

require_relative "helpers"

CURRENT_BACKEND = (ENV['MESSAGE_BUS_BACKEND'] || :redis).to_sym

if CURRENT_BACKEND == :active_record
  setup_ar_db
end

require "message_bus/backends/#{CURRENT_BACKEND}"

if CURRENT_BACKEND == :active_record
  create_message_bus_db
end

BACKEND_CLASS = MessageBus::BACKENDS.fetch(CURRENT_BACKEND)

puts "Running with backend: #{CURRENT_BACKEND}"

def test_only(*backends)
  skip "Test doesn't apply to #{CURRENT_BACKEND}" unless backends.include?(CURRENT_BACKEND)
end

def test_never(*backends)
  skip "Test doesn't apply to #{CURRENT_BACKEND}" if backends.include?(CURRENT_BACKEND)
end

module MinitestHooks
  def before_setup(*, **, &blk)
    super
    ::Redis.new(url: ENV['REDISURL']).flushdb
    begin
      PG::Connection.connect.exec("TRUNCATE TABLE #{ENV['PGDATABASE']} RESTART IDENTITY")
    rescue PG::UndefinedTable
    end
  end
end

Minitest::Test.include(MinitestHooks)
