# frozen_string_literal: true

module MessageBus
  module Codec
    class Base
      def encode(data:, user_ids:, group_ids:, client_ids:)
        raise ConcreteClassMustImplementError
      end

      def decode(payload)
        raise ConcreteClassMustImplementError
      end
    end

    autoload :Json, File.expand_path("json", __dir__)
    autoload :Oj, File.expand_path("oj", __dir__)
    autoload :OjFast, File.expand_path("oj_fast", __dir__)
  end
end
