# frozen_string_literal: true

# there is also another in cramp this is from https://github.com/macournoyer/thin_async/blob/master/lib/thin/async.rb
module Thin
  unless defined?(DeferrableBody)
    # Based on version from James Tucker <raggi@rubyforge.org>
    class DeferrableBody
      include ::EM::Deferrable

      def initialize
        @queue = []
        @body_callback = nil
      end

      def call(body)
        @queue << body
        schedule_dequeue
      end

      def each(&blk)
        @body_callback = blk
        schedule_dequeue
      end

      private

      def schedule_dequeue
        return unless @body_callback

        ::EM.next_tick do
          next unless body = @queue.shift

          body.each do |chunk|
            @body_callback.call(chunk)
          end
          schedule_dequeue unless @queue.empty?
        end
      end
    end
  end

  # Response which body is sent asynchronously.
  class AsyncResponse
    include Rack::Response::Helpers

    attr_reader :headers, :callback, :closed
    attr_accessor :status

    def initialize(env, status = 200, headers = {})
      @callback = env['async.callback']
      @body = DeferrableBody.new
      @status = status
      @headers = headers
      @headers_sent = false
    end

    def send_headers
      return if @headers_sent

      @callback.call [@status, @headers, @body]
      @headers_sent = true
    end

    def write(body)
      send_headers
      @body.call(body.respond_to?(:each) ? body : [body])
    end
    alias :<< :write

    # Tell Thin the response is complete and the connection can be closed.
    def done
      @closed = true
      send_headers
      ::EM.next_tick { @body.succeed }
    end
  end
end
