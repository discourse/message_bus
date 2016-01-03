require 'spec_helper'
require 'message_bus'

describe MessageBus::Client do

  describe "subscriptions" do

    before do
      @bus = MessageBus::Instance.new
      @client = MessageBus::Client.new client_id: 'abc', message_bus: @bus
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
        name,val = line.split(": ")
        headers[name] = val
      end

      length = nil
      while line = lines.shift
        length = line.to_i(16)
        break if length == 0
        rest = lines.join("\r\n")
        chunks << rest[0...length]
        lines = (rest[length+2..-1] || "").split("\r\n")
      end

      [status, headers, chunks]
    end

    def parse_chunk(data)
      split = data.split("\r\n")
      length = split[0].to_i(16)
      payload = split[1..-1].join("\r\n")[0...length]
      JSON.parse(payload)
    end

    it "can chunk replies" do
      @client.use_chunked = true
      r,w = IO.pipe
      @client.io = w
      @client.headers = {"Content-Type" => "application/json; charset=utf-8"}
      @client << MessageBus::Message.new(1, 1, '/test', 'test')
      @client << MessageBus::Message.new(2, 2, '/test', 'test2')

      lines = r.read_nonblock(8000)

      status, headers, chunks = http_parse(lines)

      headers["Content-Type"].should == "text/plain; charset=utf-8"
      status.should == "200"
      chunks.length.should == 2

      chunk1 = parse_chunk(chunks[0])
      chunk1.length.should == 1
      chunk1.first["data"].should == 'test'

      chunk2 = parse_chunk(chunks[1])
      chunk2.length.should == 1
      chunk2.first["data"].should == 'test2'

      @client << MessageBus::Message.new(3, 3, '/test', 'test3')
      @client.close

      data = r.read

      data[-5..-1].should == "0\r\n\r\n"

      _,_,chunks = http_parse("HTTP/1.1 200 OK\r\n\r\n" << data)

      chunks.length.should == 2

      chunk1 = parse_chunk(chunks[0])
      chunk1.length.should == 1
      chunk1.first["data"].should == 'test3'

      # end with []
      chunk2 = parse_chunk(chunks[1])
      chunk2.length.should == 0

    end

    it "does not bleed data accross sites" do
      @client.site_id = "test"

      @client.subscribe('/hello', nil)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log.length.should == 0
    end

    it "does not bleed status accross sites" do
      @client.site_id = "test"

      @client.subscribe('/hello', -1)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log[0].data.should == {"/hello" => 0}
    end

    it "provides status" do
      @client.subscribe('/hello', -1)
      log = @client.backlog
      log.length.should == 1
      log[0].data.should == {"/hello" => 0}
    end

    it "should provide a list of subscriptions" do
      @client.subscribe('/hello', nil)
      @client.subscriptions['/hello'].should_not be_nil
    end

    it "should provide backlog for subscribed channel" do
      @client.subscribe('/hello', nil)
      @bus.publish '/hello', 'world'
      log = @client.backlog
      log.length.should == 1
      log[0].channel.should == '/hello'
      log[0].data.should == 'world'
    end

    it "allows only client_id in list if message contains client_ids" do
      @message = MessageBus::Message.new(1, 2, '/test', 'hello')
      @message.client_ids = ["1","2"]
      @client.client_id = "2"
      @client.allowed?(@message).should == true

      @client.client_id = "3"
      @client.allowed?(@message).should == false
    end

    context "targetted at group" do
      before do
        @message = MessageBus::Message.new(1,2,'/test', 'hello')
        @message.group_ids = [1,2,3]
      end

      it "denies users that are not members of group" do
        @client.group_ids = [77,0,10]
        @client.allowed?(@message).should == false
      end

      it "allows users that are members of group" do
        @client.group_ids = [1,2,3]
        @client.allowed?(@message).should == true
      end

      it "allows all users if groups not set" do
        @message.group_ids = nil
        @client.group_ids = [77,0,10]
        @client.allowed?(@message).should == true
      end

    end
  end

end
