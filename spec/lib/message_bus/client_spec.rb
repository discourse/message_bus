require_relative '../../spec_helper'
require 'message_bus'

describe MessageBus::Client do
  describe "subscriptions" do
    def setup_client(client_id)
      MessageBus::Client.new client_id: client_id, message_bus: @bus
    end

    before do
      @bus = MessageBus::Instance.new
      @bus.configure(MESSAGE_BUS_CONFIG)
      @client = setup_client('abc')
    end

    after do
      @bus.reset!
      @bus.destroy
    end

    def http_parse(message)
      lines = message.split("\r\n")

      status = lines.shift.split(" ")[1]
      headers = {}
      chunks = []

      while line = lines.shift
        break if line == ""

        name, val = line.split(": ")
        headers[name] = val
      end

      while line = lines.shift
        length = line.to_i(16)
        break if length == 0

        rest = lines.join("\r\n")
        chunks << rest[0...length]
        lines = (rest[length + 2..-1] || "").split("\r\n")
      end

      # split/join gets tricky
      chunks[-1] << "\r\n"

      [status, headers, chunks]
    end

    def parse_chunk(data)
      payload, _ = data.split(/\r\n\|\r\n/m)
      JSON.parse(payload)
    end

    it "can chunk replies" do
      @client.use_chunked = true
      r, w = IO.pipe
      @client.io = w
      @client.headers = { "Content-Type" => "application/json; charset=utf-8" }
      @client << MessageBus::Message.new(1, 1, '/test', 'test')
      @client << MessageBus::Message.new(2, 2, '/test', "a|\r\n|\r\n|b")

      lines = r.read_nonblock(8000)

      status, headers, chunks = http_parse(lines)

      headers["Content-Type"].must_equal "text/plain; charset=utf-8"
      status.must_equal "200"
      chunks.length.must_equal 2

      chunk1 = parse_chunk(chunks[0])
      chunk1.length.must_equal 1
      chunk1.first["data"].must_equal 'test'

      chunk2 = parse_chunk(chunks[1])
      chunk2.length.must_equal 1
      chunk2.first["data"].must_equal "a|\r\n|\r\n|b"

      @client << MessageBus::Message.new(3, 3, '/test', 'test3')
      @client.close

      data = r.read

      data[-5..-1].must_equal "0\r\n\r\n"

      _, _, chunks = http_parse("HTTP/1.1 200 OK\r\n\r\n" << data)

      chunks.length.must_equal 2

      chunk1 = parse_chunk(chunks[0])
      chunk1.length.must_equal 1
      chunk1.first["data"].must_equal 'test3'

      # end with []
      chunk2 = parse_chunk(chunks[1])
      chunk2.length.must_equal 0
    end

    it "does not bleed data accross sites" do
      @client.site_id = "test"

      @client.subscribe('/hello', nil)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log.length.must_equal 0
    end

    it "does not bleed status accross sites" do
      @client.site_id = "test"

      @client.subscribe('/hello', -1)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log[0].data.must_equal("/hello" => 0)
    end

    it "allows negative subscribes to look behind" do
      @bus.publish '/hello', 'world'
      @bus.publish '/hello', 'sam'

      @client.subscribe('/hello', -2)

      log = @client.backlog
      log.length.must_equal(1)
      log[0].data.must_equal("sam")
    end

    it "provides status" do
      @client.subscribe('/hello', -1)
      log = @client.backlog
      log.length.must_equal 1
      log[0].data.must_equal("/hello" => 0)
    end

    it 'provides status updates to clients that are not allowed to a message' do
      another_client = setup_client('def')
      clients = [@client, another_client]

      channel = SecureRandom.hex

      clients.each { |client| client.subscribe(channel, nil) }

      @bus.publish(channel, "world", client_ids: ['abc'])

      log = @client.backlog
      log.length.must_equal 1
      log[0].channel.must_equal channel
      log[0].data.must_equal 'world'

      log = another_client.backlog
      log.length.must_equal 1
      log[0].channel.must_equal '/__status'
      log[0].data.must_equal(channel => 1)
    end

    it "should provide a list of subscriptions" do
      @client.subscribe('/hello', nil)
      @client.subscriptions['/hello'].wont_equal nil
    end

    it "should provide backlog for subscribed channel" do
      @client.subscribe('/hello', nil)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log.length.must_equal 1
      log[0].channel.must_equal '/hello'
      log[0].data.must_equal 'world'
    end

    it "allows only client_id in list if message contains client_ids" do
      @message = MessageBus::Message.new(1, 2, '/test', 'hello')
      @message.client_ids = ["1", "2"]
      @client.client_id = "2"
      @client.allowed?(@message).must_equal true

      @client.client_id = "3"
      @client.allowed?(@message).must_equal false
    end

    describe "targetted at group" do
      before do
        @message = MessageBus::Message.new(1, 2, '/test', 'hello')
        @message.group_ids = [1, 2, 3]
      end

      it "denies users that are not members of group" do
        @client.group_ids = [77, 0, 10]
        @client.allowed?(@message).must_equal false
      end

      it "allows users that are members of group" do
        @client.group_ids = [1, 2, 3]
        @client.allowed?(@message).must_equal true
      end

      it "allows all users if groups not set" do
        @message.group_ids = nil
        @client.group_ids = [77, 0, 10]
        @client.allowed?(@message).must_equal true
      end
    end
  end
end
