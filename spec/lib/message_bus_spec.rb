require_relative '../spec_helper'
require 'message_bus'
require 'redis'

describe MessageBus do
  before do
    @bus = MessageBus::Instance.new
    @bus.site_id_lookup do
      "magic"
    end
    @bus.configure(MESSAGE_BUS_CONFIG)
  end

  after do
    @bus.reset!
    @bus.destroy
  end

  it "can be turned off" do
    @bus.off

    @bus.off?.must_equal true
  end

  it "can call destroy twice" do
    @bus.destroy
    @bus.destroy
  end

  it "can be turned on after destroy" do
    @bus.destroy

    @bus.on

    @bus.after_fork
  end

  it "can subscribe from a point in time" do
    @bus.publish("/minion", "banana")

    data1 = []
    data2 = []
    data3 = []

    @bus.subscribe("/minion") do |msg|
      data1 << msg.data
    end

    @bus.subscribe("/minion", 0) do |msg|
      data2 << msg.data
    end

    @bus.subscribe("/minion", 1) do |msg|
      data3 << msg.data
    end

    @bus.publish("/minion", "bananana")
    @bus.publish("/minion", "it's so fluffy")

    wait_for(2000) do
      data3.length == 3 && data2.length == 3 && data1.length == 2
    end

    data1.must_equal ['bananana', "it's so fluffy"]
    data2.must_equal ['banana', 'bananana', "it's so fluffy"]
    data3.must_equal ['banana', 'bananana', "it's so fluffy"]
  end

  it "can transmit client_ids" do
    client_ids = nil

    @bus.subscribe("/chuck") do |msg|
      client_ids = msg.client_ids
    end

    @bus.publish("/chuck", { yeager: true }, client_ids: ['a', 'b'])
    wait_for(2000) { client_ids }

    client_ids.must_equal ['a', 'b']
  end

  it "should recover from a redis flush" do
    data = nil
    @bus.subscribe("/chuck") do |msg|
      data = msg.data
    end
    @bus.publish("/chuck", norris: true)
    @bus.publish("/chuck", norris: true)
    @bus.publish("/chuck", norris: true)

    @bus.reliable_pub_sub.reset!

    @bus.publish("/chuck", yeager: true)

    wait_for(2000) { data && data["yeager"] }

    data["yeager"].must_equal true
  end

  it "should recover from a backlog expiring" do
    data = nil
    @bus.subscribe("/chuck") do |msg|
      data = msg.data
    end
    @bus.publish("/chuck", norris: true)
    @bus.publish("/chuck", norris: true)
    @bus.publish("/chuck", norris: true)

    @bus.reliable_pub_sub.expire_all_backlogs!

    @bus.publish("/chuck", yeager: true)

    wait_for(2000) { data && data["yeager"] }

    data["yeager"].must_equal true
  end

  it "should automatically decode hashed messages" do
    data = nil
    @bus.subscribe("/chuck") do |msg|
      data = msg.data
    end
    @bus.publish("/chuck", norris: true)
    wait_for(2000) { data }

    data["norris"].must_equal true
  end

  it "should get a message if it subscribes to it" do
    user_ids, data, site_id, channel = nil

    @bus.subscribe("/chuck") do |msg|
      data = msg.data
      site_id = msg.site_id
      channel = msg.channel
      user_ids = msg.user_ids
    end

    @bus.publish("/chuck", "norris", user_ids: [1, 2, 3])

    wait_for(2000) { data }

    data.must_equal 'norris'
    site_id.must_equal 'magic'
    channel.must_equal '/chuck'
    user_ids.must_equal [1, 2, 3]
  end

  it "should get global messages if it subscribes to them" do
    data, site_id, channel = nil

    @bus.subscribe do |msg|
      data = msg.data
      site_id = msg.site_id
      channel = msg.channel
    end

    @bus.publish("/chuck", "norris")

    wait_for(2000) { data }

    data.must_equal 'norris'
    site_id.must_equal 'magic'
    channel.must_equal '/chuck'
  end

  it "should have the ability to grab the backlog messages in the correct order" do
    id = @bus.publish("/chuck", "norris")
    @bus.publish("/chuck", "foo")
    @bus.publish("/chuck", "bar")

    r = @bus.backlog("/chuck", id)

    r.map { |i| i.data }.to_a.must_equal ['foo', 'bar']
  end

  it "should correctly get full backlog of a channel" do
    @bus.publish("/chuck", "norris")
    @bus.publish("/chuck", "foo")
    @bus.publish("/chuckles", "bar")

    @bus.backlog("/chuck").map { |i| i.data }.to_a.must_equal ['norris', 'foo']
  end

  it "allows you to look up last_message" do
    @bus.publish("/bob", "dylan")
    @bus.publish("/bob", "marley")
    @bus.last_message("/bob").data.must_equal "marley"
    assert_nil @bus.last_message("/nothing")
  end

  describe "#publish" do
    it "allows publishing to a explicit site" do
      data, site_id, channel = nil

      @bus.subscribe do |msg|
        data = msg.data
        site_id = msg.site_id
        channel = msg.channel
      end

      @bus.publish("/chuck", "norris", site_id: "law-and-order")

      wait_for(2000) { data }

      data.must_equal 'norris'
      site_id.must_equal 'law-and-order'
      channel.must_equal '/chuck'
    end
  end

  describe "global subscriptions" do
    before do
      seq = 0
      @bus.site_id_lookup do
        (seq += 1).to_s
      end
    end

    it "can get last_message" do
      @bus.publish("/global/test", "test")
      @bus.last_message("/global/test").data.must_equal "test"
    end

    it "can subscribe globally" do
      data = nil
      @bus.subscribe do |message|
        data = message.data
      end

      @bus.publish("/global/test", "test")
      wait_for(1000) { data }

      data.must_equal "test"
    end

    it "can subscribe to channel" do
      data = nil
      @bus.subscribe("/global/test") do |message|
        data = message.data
      end

      @bus.publish("/global/test", "test")
      wait_for(1000) { data }

      data.must_equal "test"
    end

    it "should exception if publishing restricted messages to user" do
      lambda do
        @bus.publish("/global/test", "test", user_ids: [1])
      end.must_raise(MessageBus::InvalidMessage)
    end

    it "should exception if publishing restricted messages to group" do
      lambda do
        @bus.publish("/global/test", "test", user_ids: [1])
      end.must_raise(MessageBus::InvalidMessage)
    end
  end

  it "should support forking properly do" do
    test_never :memory

    data = []
    @bus.subscribe do |msg|
      data << msg.data
    end

    @bus.publish("/hello", "pre-fork")
    wait_for(2000) { data.length > 0 }

    if child = Process.fork
      # The child was forked and we received its PID

      # Wait for fork to finish so we're asserting that we can still publish after it has
      Process.wait(child)

      @bus.publish("/hello", "continuation")
    else
      begin
        @bus.after_fork
        @bus.publish("/hello", "from-fork")
      ensure
        exit!(0)
      end
    end

    wait_for(2000) { data.length == 3 }

    data.must_equal(["pre-fork", "from-fork", "continuation"])
  end
end
