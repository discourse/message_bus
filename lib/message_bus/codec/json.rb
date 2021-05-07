# frozen_string_literal: true

module MessageBus
  module Codec
    class Json < Base
      def encode(hash)
        JSON.dump(hash)
      end

      def decode(payload)
        JSON.parse(payload)
      end
    end
  end
end
