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
  when :active_record
    config[:pubsub_redis_url] = ENV['REDISURL']
  end
  config
end

def setup_ar_db
  require 'active_record'
  ActiveRecord::Base.configurations = [
    ActiveRecord::DatabaseConfigurations::HashConfig.new(
      'test',
      'message_bus',
      {
        adapter: "postgresql",
        username: ENV['PGUSER'],
        password: ENV['PGPASSWORD'],
        host: ENV['PGHOST'],
        port: ENV['PGPORT'],
        pool: 5,
        timeout: 5000,
        database: ENV['PGDATABASE']
      }
    )
  ]
end

def create_message_bus_db
  require 'active_record/tasks/postgresql_database_tasks'
  require 'erb'
  # Re-create the database
  ActiveRecord::Tasks::PostgreSQLDatabaseTasks.new(ActiveRecord::Base.configurations.configurations.first).purge

  migration = 'lib/message_bus/rails/generators/migrations/templates/message_bus.rb'
  eval(ERB.new(File.read(migration)).result)
  migration_class = Object.const_get("Create#{MessageBus::Rails::Message.table_name.camelcase}")
  migration_class.new.up
  MessageBus::Rails::Message.establish_connection
end
