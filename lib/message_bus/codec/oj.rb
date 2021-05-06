# frozen_string_literal: true

require 'oj' unless defined? ::Oj

module MessageBus
  module Codec
    class Oj < Base
      def encode(data:, user_ids:, group_ids:, client_ids:)
        ::Oj.dump({
            data: data,
            user_ids: user_ids,
            group_ids: group_ids,
            client_ids: client_ids
          },
          mode: :compat)
      end

      def decode(payload)
        ::Oj.load(payload, mode: :compat)
      end
    end
  end
end
