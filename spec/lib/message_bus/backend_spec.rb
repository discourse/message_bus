# frozen_string_literal: true

require_relative '../../spec_helper'
require 'message_bus'

describe BACKEND_CLASS do
  before do
    @bus = BACKEND_CLASS.new(test_config_for_backend(CURRENT_BACKEND))
  end

  after do
    @bus.reset!
    @bus.destroy
  end

  describe "API parity" do
    it "has the same public methods as the base class" do
      @bus.public_methods.sort.must_equal MessageBus::Backends::Base.new(test_config_for_backend(CURRENT_BACKEND)).public_methods.sort
    end

    it "treats request_reconnect as an optional no-op rather than an error" do
      MessageBus::Backends::Base.new.request_reconnect.must_be_nil
    end
  end

  it "should be able to access the backlog" do
    @bus.publish "/foo", "bar"
    @bus.publish "/foo", "baz"

    @bus.backlog("/foo", 0).to_a.must_equal [
      MessageBus::Message.new(1, 1, '/foo', 'bar'),
      MessageBus::Message.new(2, 2, '/foo', 'baz')
    ]
  end

  it "should initialize with max_backlog_size" do
    BACKEND_CLASS.new({}, 2000).max_backlog_size.must_equal 2000
  end

  it "should truncate channels correctly" do
    @bus.max_backlog_size = 2
    [
      "one",
      "two",
      "three",
      "four",
    ].each do |t|
      @bus.publish "/foo", t
    end

    @bus.backlog("/foo").to_a.must_equal [
      MessageBus::Message.new(3, 3, '/foo', 'three'),
      MessageBus::Message.new(4, 4, '/foo', 'four'),
    ]
  end

  it "should truncate global backlog correctly" do
    @bus.max_global_backlog_size = 2
    @bus.publish "/foo", "one"
    @bus.publish "/bar", "two"
    @bus.publish "/baz", "three"

    @bus.global_backlog.length.must_equal 2
  end

  it "should be able to grab a message by id" do
    id1 = @bus.publish "/foo", "bar"
    id2 = @bus.publish "/foo", "baz"
    @bus.get_message("/foo", id2).must_equal MessageBus::Message.new(2, 2, "/foo", "baz")
    @bus.get_message("/foo", id1).must_equal MessageBus::Message.new(1, 1, "/foo", "bar")
  end

  it "should have the correct number of messages for multi threaded access" do
    threads = []
    4.times do
      threads << Thread.new do
        25.times {
          @bus.publish "/foo", "foo"
        }
      end
    end

    threads.each(&:join)
    @bus.backlog("/foo").length.must_equal 100
  end

  it "should be able to encode and decode messages properly" do
    m = MessageBus::Message.new 1, 2, '||', '||'
    MessageBus::Message.decode(m.encode).must_equal m
  end

  it "should allow us to get last id on a channel" do
    @bus.last_id("/foo").must_equal 0
    @bus.publish("/foo", "one")
    @bus.last_id("/foo").must_equal 1
  end

  it "should allow us to get multiple last_ids" do
    @bus.last_ids("/foo", "/bar", "/foobar").must_equal [0, 0, 0]

    @bus.publish("/foo", "one")
    @bus.publish("/foo", "two")
    @bus.publish("/foobar", "three")

    @bus.last_ids("/foo", "/bar", "/foobar").must_equal(
      [
        @bus.last_id("/foo"),
        @bus.last_id("/bar"),
        @bus.last_id("/foobar")
      ]
    )
  end

  it "can set backlog age" do
    @bus.max_backlog_age = 0
    @bus.publish "/foo", "bar"

    # Redis and PostgreSQL expire synchronously during publication. The memory
    # backend normally expires on a timer, so invoke the same expiry operation
    # directly rather than making the test wait for that timer to run.
    @bus.send(:client).expire if CURRENT_BACKEND == :memory

    @bus.global_backlog.must_be_empty
    @bus.backlog("/foo", 0).must_be_empty
  end

  it "can set backlog age on publish" do
    @bus.max_backlog_age = 100
    initial_id = @bus.last_id("/foo")

    @bus.publish "/foo", "bar", max_backlog_age: 0
    @bus.send(:client).expire if CURRENT_BACKEND == :memory

    @bus.global_backlog.must_be_empty
    @bus.backlog("/foo", 0).must_be_empty

    # The memory and Redis backends discard channel ID state on expiry.
    @bus.last_id("/foo").must_equal initial_id if CURRENT_BACKEND != :postgres
  end

  it "can set backlog size on publish" do
    @bus.max_backlog_size = 100

    @bus.publish "/foo", "bar", max_backlog_size: 2
    @bus.publish "/foo", "bar", max_backlog_size: 2
    @bus.publish "/foo", "bar", max_backlog_size: 2

    @bus.backlog("/foo").length.must_equal 2
  end

  it "should be able to access the global backlog" do
    @bus.publish "/foo", "bar"
    @bus.publish "/hello", "world"
    @bus.publish "/foo", "baz"
    @bus.publish "/hello", "planet"

    expected_messages = case CURRENT_BACKEND
                        when :redis
                          # Redis has channel-specific message IDs
                          [
                            MessageBus::Message.new(1, 1, "/foo", "bar"),
                            MessageBus::Message.new(2, 1, "/hello", "world"),
                            MessageBus::Message.new(3, 2, "/foo", "baz"),
                            MessageBus::Message.new(4, 2, "/hello", "planet")
                          ]
                        else
                          [
                            MessageBus::Message.new(1, 1, "/foo", "bar"),
                            MessageBus::Message.new(2, 2, "/hello", "world"),
                            MessageBus::Message.new(3, 3, "/foo", "baz"),
                            MessageBus::Message.new(4, 4, "/hello", "planet")
                          ]
    end

    @bus.global_backlog.to_a.must_equal expected_messages
  end

  it "should correctly omit dropped messages from the global backlog" do
    @bus.max_backlog_size = 1
    @bus.publish "/foo", "a1"
    @bus.publish "/foo", "b1"
    @bus.publish "/bar", "a1"
    @bus.publish "/bar", "b1"

    expected_messages = case CURRENT_BACKEND
                        when :redis
                          # Redis has channel-specific message IDs
                          [
                            MessageBus::Message.new(2, 2, "/foo", "b1"),
                            MessageBus::Message.new(4, 2, "/bar", "b1")
                          ]
                        else
                          [
                            MessageBus::Message.new(2, 2, "/foo", "b1"),
                            MessageBus::Message.new(4, 4, "/bar", "b1")
                          ]
    end

    @bus.global_backlog.to_a.must_equal expected_messages
  end

  it "should cope with a storage reset cleanly" do
    @bus.publish("/foo", "one")
    got = []

    t = Thread.new do
      @bus.subscribe("/foo") do |msg|
        got << msg
      end
    end

    # sleep 50ms to allow the bus to correctly subscribe,
    #   I thought about adding a subscribed callback, but outside of testing it matters less
    sleep 0.05

    @bus.publish("/foo", "two")

    @bus.reset!

    @bus.publish("/foo", "three")

    wait_for(100) do
      got.length == 2
    end

    t.kill

    got.map { |m| m.data }.must_equal ["two", "three"]
    got[1].global_id.must_equal 1
  end

  it "should support clear_every setting" do
    @bus.clear_every = 5
    @bus.max_global_backlog_size = 2
    @bus.publish "/foo", "11"
    @bus.publish "/bar", "21"
    @bus.publish "/baz", "31"
    @bus.publish "/bar", "41"
    @bus.global_backlog.length.must_equal 4

    @bus.publish "/baz", "51"
    @bus.global_backlog.length.must_equal 2
  end

  it "should be able to subscribe globally with recovery" do
    @bus.publish("/foo", "11")
    @bus.publish("/bar", "12")
    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    @bus.publish("/bar", "13")

    wait_for(100) do
      got.length == 3
    end

    t.kill

    got.length.must_equal 3
    got.map { |m| m.data }.must_equal ["11", "12", "13"]
  end

  it "should handle subscribe on single channel, with recovery" do
    @bus.publish("/foo", "11")
    @bus.publish("/bar", "12")
    got = []

    t = Thread.new do
      @bus.subscribe("/foo", 0) do |msg|
        got << msg
      end
    end

    @bus.publish("/foo", "13")

    wait_for(100) do
      got.length == 2
    end

    t.kill

    got.map { |m| m.data }.must_equal ["11", "13"]
  end

  it "should not get backlog if subscribe is called without params" do
    @bus.publish("/foo", "11")
    got = []

    t = Thread.new do
      @bus.subscribe("/foo") do |msg|
        got << msg
      end
    end

    # sleep 50ms to allow the bus to correctly subscribe,
    #   I thought about adding a subscribed callback, but outside of testing it matters less
    sleep 0.05

    @bus.publish("/foo", "12")

    wait_for(100) do
      got.length == 1
    end

    t.kill

    got.map { |m| m.data }.must_equal ["12"]
  end

  it "tolerates request_reconnect when nothing is subscribed" do
    @bus.request_reconnect

    @bus.publish("/reconnect-noop", "bar")

    @bus.backlog("/reconnect-noop", 0).map(&:data).must_equal ["bar"]
  end

  it "retries global_subscribe after a redis subscribe failure" do
    test_only(:redis)

    log_output = StringIO.new
    @bus.instance_variable_set(:@logger, Logger.new(log_output))

    fail_first_subscribe = true
    real_new_redis_connection = @bus.method(:new_redis_connection)

    @bus.define_singleton_method(:new_redis_connection) do
      redis = real_new_redis_connection.call

      if fail_first_subscribe
        fail_first_subscribe = false
        redis.define_singleton_method(:subscribe) do |_channel, &_blk|
          raise IOError, "forced subscribe failure"
        end
      end

      redis
    end

    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    wait_for(4000) { log_output.string.include?("forced subscribe failure") }
    wait_for(5000) { @bus.subscribed }

    @bus.publish("/redis-retry", "delivered-after-retry")
    wait_for(3000) { got.any? { |m| m.data == "delivered-after-retry" } }

    @bus.global_unsubscribe
    t.join(2)
    t.kill if t.alive?

    log_output.string.must_include "subscribe failed, reconnecting in 1 second"
    got.map(&:data).must_include "delivered-after-retry"
  end

  it "retries global_subscribe after request_reconnect disconnects redis" do
    test_only(:redis)

    log_output = StringIO.new
    @bus.instance_variable_set(:@logger, Logger.new(log_output))
    subscribe_attempts = 0
    real_new_redis_connection = @bus.method(:new_redis_connection)

    @bus.define_singleton_method(:new_redis_connection) do
      redis = real_new_redis_connection.call
      real_subscribe = redis.method(:subscribe)
      redis.define_singleton_method(:subscribe) do |*args, &blk|
        subscribe_attempts += 1
        real_subscribe.call(*args, &blk)
      end
      redis
    end

    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }
    wait_for(5000) { subscribe_attempts >= 1 }

    @bus.publish("/redis-reconnect", "before-reconnect")
    wait_for(3000) { got.any? { |m| m.data == "before-reconnect" } }

    @bus.request_reconnect

    wait_for(7000) { log_output.string.include?("subscribe failed, reconnecting in 1 second") }
    wait_for(7000) { subscribe_attempts >= 2 }

    @bus.publish("/redis-reconnect", "after-reconnect")
    wait_for(5000) { got.any? { |m| m.data == "after-reconnect" } }

    @bus.global_unsubscribe
    t.join(2)
    t.kill if t.alive?

    got.map(&:data).must_include "after-reconnect"
    subscribe_attempts.must_be :>=, 2
  end

  it "replays messages published during a reconnect window without loss or duplication" do
    test_never(:memory)

    log_output = capture_backend_log(@bus)
    speed_up_reconnect_detection(@bus)

    got = []

    t = Thread.new do
      @bus.global_subscribe do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }

    @bus.publish("/reconnect-continuity", "before")
    wait_for(3000) { got.any? { |m| m.data == "before" } }

    @bus.request_reconnect
    wait_for(7000) { log_output.string.include?("subscribe failed, reconnecting in 1 second") }

    @bus.publish("/reconnect-continuity", "during")

    wait_for(7000) { @bus.subscribed }

    @bus.publish("/reconnect-continuity", "after")
    wait_for(5000) { got.any? { |m| m.data == "after" } }

    @bus.global_unsubscribe
    t.join(3)
    t.kill if t.alive?

    got.map(&:data).must_equal ["before", "during", "after"]
  end

  it "replays a message published during a reconnect window that opened before any message was received" do
    test_never(:memory)

    log_output = capture_backend_log(@bus)
    speed_up_reconnect_detection(@bus)

    got = []

    t = Thread.new do
      @bus.global_subscribe do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }

    # Request reconnect before any live message has been received, so the
    # backend has never had a chance to derive a cursor from a message: it
    # must fall back to the cursor seeded at subscription start.
    @bus.request_reconnect
    wait_for(7000) { log_output.string.include?("subscribe failed, reconnecting in 1 second") }

    @bus.publish("/reconnect-continuity-cold", "during")

    wait_for(7000) { @bus.subscribed }

    @bus.publish("/reconnect-continuity-cold", "after")
    wait_for(5000) { got.any? { |m| m.data == "after" } }

    @bus.global_unsubscribe
    t.join(3)
    t.kill if t.alive?

    got.map(&:data).must_equal ["during", "after"]
  end

  it "reports subscribed as false during a reconnect window and true once replaced" do
    test_never(:memory)

    log_output = capture_backend_log(@bus)
    speed_up_reconnect_detection(@bus)

    got = []

    t = Thread.new do
      @bus.global_subscribe do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }

    @bus.request_reconnect
    wait_for(7000) { log_output.string.include?("subscribe failed, reconnecting in 1 second") }

    @bus.subscribed.must_equal false

    wait_for(7000) { @bus.subscribed }
    @bus.subscribed.must_equal true

    @bus.global_unsubscribe
    t.join(3)
    t.kill if t.alive?
  end

  it "reconnects the postgres subscriber from its own thread" do
    test_only(:postgres)

    log_output = StringIO.new
    @bus.instance_variable_get(:@config)[:logger] = Logger.new(log_output)
    recorded = instrument_postgres_client(@bus)

    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }

    @bus.publish("/pg-reconnect", "before-reconnect")
    wait_for(3000) { got.any? { |m| m.data == "before-reconnect" } }

    @bus.request_reconnect
    wait_for(7000) { recorded[:subscribes].length >= 2 }

    # ReconnectRequested is raised before on.unsubscribe fires, so @subscribed
    # must already have been reset explicitly by the rescue path.
    @bus.subscribed.must_equal false

    @bus.publish("/pg-reconnect", "during-reconnect")

    wait_for(5000) { @bus.subscribed }

    @bus.publish("/pg-reconnect", "after-reconnect")
    wait_for(5000) { got.any? { |m| m.data == "after-reconnect" } }

    @bus.global_unsubscribe
    t.join(3)
    t.kill if t.alive?

    # Exact order, no duplicates, no loss: the cursor must be advanced by
    # every accepted live message and carried across the reconnect.
    got.map(&:data).must_equal ["before-reconnect", "during-reconnect", "after-reconnect"]
    log_output.string.must_include "subscribe failed, reconnecting in 1 second"

    # Regression check: only the subscriber thread may close its own PGconn.
    recorded[:close_threads].uniq.must_equal [t]
  end

  it "ignores a postgres reconnect request made while nothing was subscribed" do
    test_only(:postgres)

    recorded = instrument_postgres_client(@bus)
    @bus.request_reconnect

    got = []

    t = Thread.new do
      @bus.global_subscribe(0) do |msg|
        got << msg
      end
    end

    wait_for(5000) { @bus.subscribed }

    @bus.publish("/pg-stale-reconnect", "delivered")
    wait_for(3000) { got.any? { |m| m.data == "delivered" } }

    @bus.global_unsubscribe
    t.join(3)
    t.kill if t.alive?

    recorded[:subscribes].length.must_equal 1
  end
end
