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

    it "should provide positions if client subscribes at -1" do
      10.times do
        @bus.publish('/hello', 'world')
      end
      @bus.publish('/shorter', 'channel')

      @client.subscribe('/hello', '-1')
      @client.subscribe('/shorter', '-1')

      log = @client.backlog(allow_flush: true)

      log.length.should == 1
      log[0].channel.should == '/__status'
      log[0].data.should == {
          '/hello' => 10,
          '/shorter' => 1
      }
    end

    it "should deliver a flush message if the client is ahead" do
      @bus.publish('/hello', 'world')
      position = @bus.last_id('/hello')

      @client.subscribe('/no_messages', nil)
      @client.subscribe('/hello', 100)

      log = @client.backlog(allow_flush: true)

      log.length.should == 2
      log[0].channel.should == '/__flush'
      log[1].channel.should == '/__status'
      log[1].data.should == {
          '/no_messages' => 0,
          '/hello' => 1
      }
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
