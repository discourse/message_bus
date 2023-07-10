# frozen_string_literal: true

gem 'activerecord', '>= 6' # Require activerecord gem v6+

module MessageBus
  module Rails
    class MessageBusRecord < ::ActiveRecord::Base
      self.abstract_class = true

      connects_to database: { writing: :message_bus, reading: :message_bus }
    end
  end
end
