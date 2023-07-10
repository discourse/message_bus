# frozen_string_literal: true

require 'rails/generators/migration'
require 'message_bus/rails/models/message'

module MessageBus
  class MessageBusMigrationGenerator < ::Rails::Generators::Base
    include ::Rails::Generators::Migration

    source_root File.expand_path('templates', __dir__)
    desc "Create migrations for ActiveRecord adapter of MessageBus"

    # @param migrations_root [String]
    # @return [String]
    def self.next_migration_number(migrations_root)
      paths = Dir["#{migrations_root}/*.rb"].map do |path|
        File.basename(path)
      end
      # Sort by the first part of "20230704104003_create_yousty_eventsourcing_messages.rb"(which is a number)
      timestamps = paths.map { |name| name.split('_').first }
      latest = timestamps.sort.last || '0'
      [Time.now.utc.strftime("%Y%m%d%H%M%S"), "%.14d" % latest.next].max
    end

    def create
      migration_template("message_bus.rb", "db/#{db_name}/create_#{table_name}.rb")
    end

    private

    def db_name
      MessageBus::Rails::Message.connection_db_config.configuration_hash[:database]
    end

    def table_name
      MessageBus::Rails::Message.table_name
    end
  end
end
