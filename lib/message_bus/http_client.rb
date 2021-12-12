# frozen_string_literal: true
require 'securerandom'
require 'net/http'
require 'json'
require 'uri'
require 'message_bus/http_client/channel'

module MessageBus
  # MessageBus client that enables subscription via long polling with support
  # for chunked encoding. Falls back to normal polling if long polling is not
  # available.
  #
  # @!attribute [r] channels
  #   @return [Hash] a map of the channels that the client is subscribed to
  # @!attribute [r] stats
  #   @return [Stats] a Struct containing the statistics of failed and successful
  #     polling requests
  #
  # @!attribute enable_long_polling
  #   @return [Boolean] whether long polling is enabled
  # @!attribute status
  #   @return [HTTPClient::STOPPED, HTTPClient::STARTED] the status of the client.
  # @!attribute enable_chunked_encoding
  #   @return [Boolean] whether chunked encoding is enabled
  # @!attribute min_poll_interval
  #   @return [Float] the min poll interval for long polling in seconds
  # @!attribute max_poll_interval
  #   @return [Float] the max poll interval for long polling in seconds
  # @!attribute background_callback_interval
  #   @return [Float] the polling interval in seconds
  class HTTPClient
    class InvalidChannel < StandardError; end
    class MissingBlock < StandardError; end

    attr_reader :channels,
                :stats

    attr_accessor :enable_long_polling,
                  :status,
                  :enable_chunked_encoding,
                  :min_poll_interval,
                  :max_poll_interval,
                  :background_callback_interval

    CHUNK_SEPARATOR = "\r\n|\r\n".freeze
    private_constant :CHUNK_SEPARATOR
    STATUS_CHANNEL = "/__status".freeze
    private_constant :STATUS_CHANNEL

    STOPPED = 0
    STARTED = 1

    Stats = Struct.new(:failed, :success)
    private_constant :Stats

    # @param base_url [String] Base URL of the message_bus server to connect to
    # @param enable_long_polling [Boolean] Enable long polling
    # @param enable_chunked_encoding [Boolean] Enable chunk encoding
    # @param min_poll_interval [Float, Integer] Min poll interval when long polling in seconds
    # @param max_poll_interval [Float, Integer] Max poll interval when long polling in seconds.
    #   When requests fail, the client will backoff and this is the upper limit.
    # @param background_callback_interval [Float, Integer] Interval to poll when
    #   when polling in seconds.
    # @param headers [Hash] extra HTTP headers to be set on the polling requests.
    #
    # @return [Object] Instance of MessageBus::HTTPClient
    def initialize(base_url, enable_long_polling: true,
                             enable_chunked_encoding: true,
                             min_poll_interval: 0.1,
                             max_poll_interval: 180,
                             background_callback_interval: 60,
                             headers: {})

      @uri = URI(base_url)
      @enable_long_polling = enable_long_polling
      @enable_chunked_encoding = enable_chunked_encoding
      @min_poll_interval = min_poll_interval
      @max_poll_interval = max_poll_interval
      @background_callback_interval = background_callback_interval
      @headers = headers
      @client_id = SecureRandom.hex
      @channels = {}
      @status = STOPPED
      @mutex = Mutex.new
      @stats = Stats.new(0, 0)
    end

    # Starts a background thread that polls the message bus endpoint
    # for the given base_url.
    #
    # Intervals for long polling can be configured via min_poll_interval and
    # max_poll_interval.
    #
    # Intervals for polling can be configured via background_callback_interval.
    #
    # @return [Object] Instance of MessageBus::HTTPClient
    def start
      @mutex.synchronize do
        return if started?

        @status = STARTED

        thread = Thread.new do
          begin
            while started?
              unless @channels.empty?
                poll
                @stats.success += 1
                @stats.failed = 0
              end

              sleep interval
            end
          rescue StandardError => e
            @stats.failed += 1
            warn("#{e.class} #{e.message}: #{e.backtrace.join("\n")}")
            sleep interval
            retry
          ensure
            stop
          end
        end

        thread.abort_on_exception = true
      end

      self
    end

    # Stops the client from polling the message bus endpoint.
    #
    # @return [Integer] the current status of the client
    def stop
      @status = STOPPED
    end

    # Subscribes to a channel which executes the given callback when a message
    # is published to the channel
    #
    # @example Subscribing to a channel for message
    #   client = MessageBus::HTTPClient.new('http://some.test.com')
    #
    #   client.subscribe("/test") do |payload, _message_id, _global_id|
    #     puts payload
    #   end
    #
    # A last_message_id may be provided.
    #  * -1 will subscribe to all new messages
    #  * -2 will receive last message + all new messages
    #  * -3 will receive last 2 message + all new messages
    #
    # @example Subscribing to a channel with `last_message_id`
    #   client.subscribe("/test", last_message_id: -2) do |payload|
    #     puts payload
    #   end
    #
    # @param channel [String] channel to listen for messages on
    # @param last_message_id [Integer] last message id to start polling on.
    #
    # @yield [data, message_id, global_id]
    #  callback to be executed whenever a message is received
    #
    # @yieldparam data [Hash] data payload of the message received on the channel
    # @yieldparam message_id [Integer] id of the message in the channel
    # @yieldparam global_id [Integer] id of the message in the global backlog
    # @yieldreturn [void]
    #
    # @return [Integer] the current status of the client
    def subscribe(channel, last_message_id: nil, &callback)
      raise InvalidChannel unless channel.to_s.start_with?("/")
      raise MissingBlock unless block_given?

      last_message_id = -1 if last_message_id && !last_message_id.is_a?(Integer)

      @channels[channel] ||= Channel.new
      channel = @channels[channel]
      channel.last_message_id = last_message_id if last_message_id
      channel.callbacks.push(callback)
      start if stopped?
    end

    # unsubscribes from a channel
    #
    # @example Unsubscribing from a channel
    #   client = MessageBus::HTTPClient.new('http://some.test.com')
    #   callback = -> { |payload| puts payload }
    #   client.subscribe("/test", &callback)
    #   client.unsubscribe("/test")
    #
    # If a callback is given, only the specific callback will be unsubscribed.
    #
    # @example Unsubscribing a callback from a channel
    #   client.unsubscribe("/test", &callback)
    #
    # When the client does not have any channels left, it will stop polling and
    # waits until a new subscription is started.
    #
    # @param channel [String] channel to unsubscribe
    # @yield [data, global_id, message_id] specific callback to unsubscribe
    #
    # @return [Integer] the current status of the client
    def unsubscribe(channel, &callback)
      if callback
        @channels[channel].callbacks.delete(callback)
        remove_channel(channel) if @channels[channel].callbacks.empty?
      else
        remove_channel(channel)
      end

      stop if @channels.empty?
      @status
    end

    private

    def stopped?
      @status == STOPPED
    end

    def started?
      @status == STARTED
    end

    def remove_channel(channel)
      @channels.delete(channel)
    end

    def interval
      if @enable_long_polling
        if (failed_count = @stats.failed) > 2
          (@min_poll_interval * 2**failed_count).clamp(
            @min_poll_interval, @max_poll_interval
          )
        else
          @min_poll_interval
        end
      else
        @background_callback_interval
      end
    end

    def poll
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = true if @uri.scheme == 'https'
      request = Net::HTTP::Post.new(request_path, headers)
      request.body = poll_payload

      if @enable_long_polling
        buffer = +""

        http.request(request) do |response|
          response.read_body do |chunk|
            unless chunk.empty?
              buffer << chunk
              process_buffer(buffer)
            end
          end
        end
      else
        response = http.request(request)
        notify_channels(JSON.parse(response.body))
      end
    end

    def is_chunked?
      !headers["Dont-Chunk"]
    end

    def process_buffer(buffer)
      index = buffer.index(CHUNK_SEPARATOR)

      if is_chunked?
        return unless index

        messages = buffer[0..(index - 1)]
        buffer.slice!("#{messages}#{CHUNK_SEPARATOR}")
      else
        messages = buffer[0..-1]
        buffer.slice!(messages)
      end

      notify_channels(JSON.parse(messages))
    end

    def notify_channels(messages)
      messages.each do |message|
        current_channel = message['channel']

        if current_channel == STATUS_CHANNEL
          message["data"].each do |channel_name, last_message_id|
            if (channel = @channels[channel_name])
              channel.last_message_id = last_message_id
            end
          end
        else
          @channels.each do |channel_name, channel|
            next unless channel_name == current_channel

            channel.last_message_id = message['message_id']

            channel.callbacks.each do |callback|
              callback.call(
                message['data'],
                channel.last_message_id,
                message['global_id']
              )
            end
          end
        end
      end
    end

    def poll_payload
      payload = {}

      @channels.each do |channel_name, channel|
        payload[channel_name] = channel.last_message_id
      end

      payload.to_json
    end

    def request_path
      "/message-bus/#{@client_id}/poll"
    end

    def headers
      headers = {}
      headers['Content-Type'] = 'application/json'
      headers['X-Silence-logger'] = 'true'

      if !@enable_long_polling || !@enable_chunked_encoding
        headers['Dont-Chunk'] = 'true'
      end

      headers.merge!(@headers)
    end
  end
end
