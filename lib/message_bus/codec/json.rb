# frozen_string_literal: true

module MessageBus
  module Codec
    class Json < Base
      def encode(data:, user_ids:, group_ids:, client_ids:)
        JSON.dump(
          data: data,
          user_ids: user_ids,
          group_ids: group_ids,
          client_ids: client_ids
        )
      end

      def decode(payload)
        JSON.parse(payload)
      end
    end
  end
end
