# frozen_string_literal: true

module MessageBus
  module Codec
    class Base
      def encode(hash)
        raise ConcreteClassMustImplementError
      end

      def decode(payload)
        raise ConcreteClassMustImplementError
      end
    end

    autoload :Json, File.expand_path("json", __dir__)
    autoload :Oj, File.expand_path("oj", __dir__)
  end
end
