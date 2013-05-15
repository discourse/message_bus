require 'spec_helper'
require 'message_bus'

describe MessageBus::Client do

  describe "subscriptions" do

    before do
      @client = MessageBus::Client.new :client_id => 'abc'
    end

    it "should provide a list of subscriptions" do
      @client.subscribe('/hello', nil)
      @client.subscriptions['/hello'].should_not be_nil
    end

    it "should provide backlog for subscribed channel" do
      @client.subscribe('/hello', nil)
      MessageBus.publish '/hello', 'world'
      log = @client.backlog
      log.length.should == 1
      log[0].channel.should == '/hello'
      log[0].data.should == 'world'
    end

    context "targetted at group" do
      before do
        @message = MessageBus::Message.new(1,2,'/test', 'hello')
        @message.group_ids = [1,2,3]
      end

      it "denies users that are not members of group" do
        @client.group_ids = [77,0,10]
        @client.allowed?(@message).should be_false
      end

      it "allows users that are members of group" do
        @client.group_ids = [1,2,3]
        @client.allowed?(@message).should be_true
      end

      it "allows all users if groups not set" do
        @message.group_ids = nil
        @client.group_ids = [77,0,10]
        @client.allowed?(@message).should be_true
      end
    end
  end

end
