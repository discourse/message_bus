# frozen_string_literal: true

module MessageBus
  module Codec
    # This codec is used along with ActiveRecord adapter because ActiveRecord does encode/decode job by itself
    class Itself < Base
      def encode(object)
        object
      end

      def decode(object)
        object
      end
    end
  end
end
