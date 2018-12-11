module MessageBus
  class HTTPClient
    # @private
    class Channel
      attr_accessor :last_message_id, :callbacks

      def initialize(last_message_id: -1, callbacks: [])
        @last_message_id = last_message_id
        @callbacks = callbacks
      end
    end
  end
end
