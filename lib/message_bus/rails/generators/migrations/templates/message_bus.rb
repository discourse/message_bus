# frozen_string_literal: true

class Create<%= MessageBus::Rails::Message.table_name.camelcase %> < ActiveRecord::Migration[7.0]
  def up
    create_table <%= MessageBus::Rails::Message.table_name.inspect %> do |t|
      t.text :channel, null: false
      t.jsonb :value, null: false
      t.datetime :added_at, null: false
    end
    execute("ALTER TABLE #{<%= MessageBus::Rails::Message.table_name.inspect %>} ALTER COLUMN added_at SET DEFAULT CURRENT_TIMESTAMP")
    add_index <%= MessageBus::Rails::Message.table_name.inspect %>, [:id, :channel]
    add_index <%= MessageBus::Rails::Message.table_name.inspect %>, :added_at
  end

  def down
    drop_table <%= MessageBus::Rails::Message.table_name.inspect %>
  end
end
