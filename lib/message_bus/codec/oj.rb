# frozen_string_literal: true

require 'oj' unless defined? ::Oj

module MessageBus
  module Codec
    class Oj < Base
      def initialize(options = { mode: :compat })
        @options = options
      end

      def encode(hash)
        ::Oj.dump(hash, @options)
      end

      def decode(payload)
        ::Oj.load(payload, @options)
      end
    end
  end
end
