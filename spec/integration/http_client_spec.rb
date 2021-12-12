# frozen_string_literal: true

require_relative '../spec_helper'
require 'message_bus/http_client'

describe MessageBus::HTTPClient do
  let(:base_url) { "http://0.0.0.0:9292" }
  let(:client) { MessageBus::HTTPClient.new(base_url) }
  let(:headers) { client.send(:headers) }
  let(:channel) { "/test" }
  let(:channel2) { "/test2" }
  let(:stats) { client.stats }

  def publish_message
    response = Net::HTTP.get_response(URI("#{base_url}/publish"))
    assert_equal("200", response.code)
  end

  before do
    @threads = Thread.list
  end

  after do
    new_threads = Thread.list - @threads
    client.stop
    new_threads.each(&:join)
  end

  describe '#start and #stop' do
    it 'should be able to start and stop polling correctly' do
      threads = Thread.list

      assert_equal(MessageBus::HTTPClient::STOPPED, client.status)

      client.start
      new_threads = Thread.list - threads

      assert_equal(1, new_threads.size)
      assert_equal(MessageBus::HTTPClient::STARTED, client.status)

      client.start

      assert_equal(new_threads, Thread.list - threads)
    end

    describe 'when an error is encountered while trying to poll' do
      let(:base_url) { "http://0.0.0.0:12312123" }

      let(:client) do
        MessageBus::HTTPClient.new(base_url, min_poll_interval: 1)
      end

      it 'should handle errors correctly' do
        begin
          original_stderr = $stderr
          $stderr = fake = StringIO.new

          client.channels[channel] = MessageBus::HTTPClient::Channel.new(
            callbacks: [-> {}]
          )

          client.start

          assert_equal(MessageBus::HTTPClient::STARTED, client.status)

          while stats.failed < 1 do
            sleep 0.05
          end

          # Sleep for more than the default min_poll_interval to ensure
          # that we sleep for the right interval after failure
          sleep 0.5

          assert_match(/Errno::ECONNREFUSED|SocketError/, fake.string)
        ensure
          $stderr = original_stderr
        end
      end
    end
  end

  describe '#subscribe' do
    it 'should be able to subscribe to channels for messages' do
      called = 0
      called2 = 0

      client.subscribe(channel, last_message_id: -1) do |data|
        called += 1
        assert_equal("world", data["hello"])
      end

      client.subscribe(channel2) do |data|
        called2 += 1
        assert_equal("world", data["hello"])
      end

      while called < 2 && called2 < 2
        publish_message
        sleep 0.05
      end

      while stats.success < 1
        sleep 0.05
      end

      assert_equal(0, stats.failed)
    end

    describe 'supports including extra headers' do
      let(:client) do
        MessageBus::HTTPClient.new(base_url, headers: {
          'Dont-Chunk' => "true"
        })
      end

      it 'should include the header in the request' do
        called = 0

        client.subscribe(channel) do |data|
          called += 1
          assert_equal("world", data["hello"])
        end

        while called < 2
          publish_message
          sleep 0.05
        end
      end
    end

    describe 'when chunked encoding is disabled' do
      let(:client) do
        MessageBus::HTTPClient.new(base_url, enable_chunked_encoding: false)
      end

      it 'should still be able to subscribe to channels for messages' do
        called = 0

        client.subscribe(channel) do |data|
          called += 1
          assert_equal("world", data["hello"])
        end

        while called < 2
          publish_message
          sleep 0.05
        end
      end
    end

    describe 'when enable_long_polling is disabled' do
      let(:client) do
        MessageBus::HTTPClient.new(base_url,
                                   enable_long_polling: false,
                                   background_callback_interval: 0.01)
      end

      it 'should still be able to subscribe to channels for messages' do
        called = 0

        client.subscribe(channel) do |data|
          called += 1
          assert_equal("world", data["hello"])
        end

        while called < 2
          publish_message
          sleep 0.05
        end
      end
    end

    describe 'when channel name is invalid' do
      it 'should raise the right error' do
        ["test", 1, :test].each do |invalid_channel|
          assert_raises MessageBus::HTTPClient::InvalidChannel do
            client.subscribe(invalid_channel)
          end
        end
      end
    end

    describe 'when a block is not given' do
      it 'should raise the right error' do
        assert_raises MessageBus::HTTPClient::MissingBlock do
          client.subscribe(channel)
        end
      end
    end

    describe 'with last_message_id' do
      describe 'when invalid' do
        it 'should subscribe from the latest message' do
          client.subscribe(channel, last_message_id: 'haha') {}
          assert_equal(-1, client.channels[channel].last_message_id)
        end
      end

      describe 'when valid' do
        it 'should subscribe from the right message' do
          client.subscribe(channel, last_message_id: -2) {}
          assert_equal(-2, client.channels[channel].last_message_id)
        end
      end
    end
  end

  describe '#unsubscribe' do
    it 'should be able to unsubscribe a channel' do
      client.subscribe(channel) { raise "Not called" }
      assert(client.channels[channel])

      client.unsubscribe(channel)
      assert_nil(client.channels[channel])
    end

    describe 'with callback' do
      it 'should be able to unsubscribe a callback for a particular channel' do
        callback = -> { raise "Not called" }
        callback2 = -> { raise "Not called2" }

        client.subscribe(channel, &callback)
        client.subscribe(channel, &callback2)
        assert_equal([callback, callback2], client.channels[channel].callbacks)

        client.unsubscribe(channel, &callback)
        assert_equal([callback2], client.channels[channel].callbacks)

        client.unsubscribe(channel, &callback2)
        assert_nil(client.channels[channel])
      end
    end
  end
end
