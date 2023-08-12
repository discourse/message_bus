# frozen_string_literal: true

require_relative 'message_bus_record'

module MessageBus
  module Rails
    class Message < MessageBusRecord
      self.table_name = 'message_bus_messages'
    end
  end
end
