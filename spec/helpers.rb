# frozen_string_literal: true

require 'logger'
require 'method_source'

def wait_for(timeout_milliseconds = 2000, &blk)
  timeout = timeout_milliseconds / 1000.0
  finish = Time.now + timeout
  result = nil

  while Time.now < finish && !(result = blk.call)
    sleep(0.001)
  end

  flunk("wait_for timed out:\n#{blk.source}") if !result
end

def test_config_for_backend(backend)
  config = {
    backend: backend,
    logger: Logger.new(IO::NULL),
  }

  case backend
  when :redis
    config[:url] = ENV['REDISURL']
  when :postgres
    config[:backend_options] = {
      host: ENV['PGHOST'],
      user: ENV['PGUSER'] || ENV['USER'],
      password: ENV['PGPASSWORD'],
      dbname: ENV['PGDATABASE'] || 'message_bus_test'
    }
  end
  config
end
