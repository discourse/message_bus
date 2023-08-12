# frozen_string_literal: true

require_relative '../../spec_helper'
require 'message_bus'

class FakeAsync
  attr_accessor :cleanup_timer

  def initialize
    @sent = nil
  end

  def <<(val)
    sleep 0.01 # simulate IO
    @sent ||= +""
    @sent << val
  end

  def sent
    @sent
  end

  def done
    @done = true
  end

  def done?
    @done
  end
end

class FakeTimer
  attr_accessor :cancelled
  def cancel
    @cancelled = true
  end
end

describe MessageBus::ConnectionManager do
  def setup_client_message_filters
    @bus.client_message_filters.map do |channel_name, filter_proc|
      [channel_name, filter_proc.curry(2).call(@params || {})]
    end
  end

  before do
    @bus = MessageBus
    @manager = MessageBus::ConnectionManager.new(@bus)
    @client = MessageBus::Client.new(
      client_id: "xyz", user_id: 1, site_id: 10, client_message_filters: setup_client_message_filters
    )
    @resp = FakeAsync.new
    @client.async_response = @resp
    @client.subscribe('test', -1)
    @manager.add_client(@client)
    @client.cleanup_timer = FakeTimer.new
  end

  it "should cancel the timer after its responds" do
    m = MessageBus::Message.new(1, 1, "test", "data")
    m.site_id = 10
    @manager.notify_clients(m)
    @client.cleanup_timer.cancelled.must_equal true
  end

  it "should be able to lookup an identical client" do
    @manager.lookup_client(@client.client_id).must_equal @client
  end

  it "should not notify clients on incorrect site" do
    m = MessageBus::Message.new(1, 1, "test", "data")
    m.site_id = 9
    @manager.notify_clients(m)
    assert_nil @resp.sent
  end

  it "should notify clients on the correct site" do
    m = MessageBus::Message.new(1, 1, "test", "data")
    m.site_id = 10
    @manager.notify_clients(m)
    @resp.sent.wont_equal nil
  end

  it "should strip site id and user id from the payload delivered" do
    m = MessageBus::Message.new(1, 1, "test", "data")
    m.user_ids = [1]
    m.site_id = 10
    @manager.notify_clients(m)
    parsed = JSON.parse(@resp.sent)
    assert_nil parsed[0]["site_id"]
    assert_nil parsed[0]["user_id"]
  end

  it "should not deliver unselected" do
    m = MessageBus::Message.new(1, 1, "test", "data")
    m.user_ids = [5]
    m.site_id = 10
    @manager.notify_clients(m)
    assert_nil @resp.sent
  end
end

describe MessageBus::ConnectionManager, "notifying and subscribing concurrently" do
  def setup_client_message_filters
    @bus.client_message_filters.map do |channel_name, filter_proc|
      [channel_name, filter_proc.curry(2).call(@params || {})]
    end
  end

  it "does not subscribe incorrect clients" do
    manager = MessageBus::ConnectionManager.new

    client1 = MessageBus::Client.new(client_id: "a", seq: 1)
    client2 = MessageBus::Client.new(client_id: "a", seq: 2)

    manager.add_client(client2)
    manager.add_client(client1)

    manager.lookup_client("a").must_equal client2
  end

  it "is thread-safe" do
    @bus = MessageBus
    @manager = MessageBus::ConnectionManager.new(@bus)

    client_threads = 10.times.map do |id|
      Thread.new do
        @client = MessageBus::Client.new(
          client_id: "xyz_#{id}", site_id: 10, client_message_filters: setup_client_message_filters
        )
        @resp = FakeAsync.new
        @client.async_response = @resp
        @client.subscribe("test", -1)
        @manager.add_client(@client)
        @client.cleanup_timer = FakeTimer.new
        1
      end
    end

    subscriber_threads = 10.times.map do |id|
      Thread.new do
        m = MessageBus::Message.new(1, id, "test", "data_#{id}")
        m.site_id = 10
        @manager.notify_clients(m)
        1
      end
    end

    client_threads.each(&:join).map(&:value).must_equal([1] * 10)
    subscriber_threads.each(&:join).map(&:value).must_equal([1] * 10)
  end
end
