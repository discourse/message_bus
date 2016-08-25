# coding: utf-8

require_relative '../../../spec_helper'
require 'message_bus'
require 'rack/test'

describe MessageBus::Rack::Middleware do
  include Rack::Test::Methods
  let(:extra_middleware){nil}

  before do
    bus = @bus = MessageBus::Instance.new
    @bus.configure(MESSAGE_BUS_CONFIG)
    @bus.long_polling_enabled = false

    e_m = extra_middleware
    builder = Rack::Builder.new {
      use FakeAsyncMiddleware, :message_bus => bus
      use e_m if e_m
      use MessageBus::Rack::Middleware, :message_bus => bus
      run lambda {|env| [500, {'Content-Type' => 'text/html'}, 'should not be called' ]}
    }

    @async_middleware = builder.to_app
    @message_bus_middleware = @async_middleware.app
    @bus.reset!
  end

  after do
    @message_bus_middleware.stop_listener
    @bus.reset!
    @bus.destroy
  end

  def app
    @async_middleware
  end

  module LongPolling
    extend Minitest::Spec::DSL

    before do
      @bus.long_polling_enabled = true
    end

    it "should respond right away if dlp=t" do
      post "/message-bus/ABC?dlp=t", '/foo1' => 0
      @async_middleware.in_async?.must_equal false
      last_response.ok?.must_equal true
    end

    it "should respond right away to long polls that are polling on -1 with the last_id" do
      post "/message-bus/ABC", '/foo' => -1
      last_response.ok?.must_equal true
      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
      parsed[0]["channel"].must_equal "/__status"
      parsed[0]["data"]["/foo"].must_equal @bus.last_id("/foo")
    end

    it "should respond to long polls when data is available" do
      middleware = @async_middleware
      bus = @bus

      @bus.extra_response_headers_lookup do |env|
        {"FOO" => "BAR"}
      end

      Thread.new do
        wait_for(2000) {middleware.in_async?}
        bus.publish "/foo", "םוֹלשָׁ"
      end

      post "/message-bus/ABC", '/foo' => nil

      last_response.ok?.must_equal true
      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
      parsed[0]["data"].must_equal "םוֹלשָׁ"

      last_response.headers["FOO"].must_equal "BAR"
    end

    it "should timeout within its alloted slot" do
      begin
        @bus.long_polling_interval = 10
        s = Time.now.to_f * 1000
        post "/message-bus/ABC", '/foo' => nil
        # allow for some jitter
        (Time.now.to_f * 1000 - s).must_be :<, 100
      ensure
        @bus.long_polling_interval = 5000
      end
    end
  end

  describe "thin async" do
    before do
      @async_middleware.simulate_thin_async
    end

    include LongPolling
  end

  describe "hijack" do
    before do
      @async_middleware.simulate_hijack
      @bus.rack_hijack_enabled = true
    end

    include LongPolling
  end

  describe "diagnostics" do

    it "should return a 403 if a user attempts to get at the _diagnostics path" do
      get "/message-bus/_diagnostics"
      last_response.status.must_equal 403
    end

    it "should get a 200 with html for an authorized user" do
      def @bus.is_admin_lookup; proc{|_| true} end
      get "/message-bus/_diagnostics"
      last_response.status.must_equal 200
    end

    it "should get the script it asks for" do
      def @bus.is_admin_lookup; proc{|_| true} end
      get "/message-bus/_diagnostics/assets/message-bus.js"
      last_response.status.must_equal 200
      last_response.content_type.must_equal "text/javascript;"
    end

  end

  describe "polling" do
    before do
      @bus.long_polling_enabled = false
    end

    it "should include access control headers" do
      @bus.extra_response_headers_lookup do |env|
        {"FOO" => "BAR"}
      end

      client_id = "ABCD"

      # client always keeps a list of channels with last message id they got on each
      post "/message-bus/#{client_id}", {
        '/foo' => nil,
        '/bar' => nil
      }

      last_response.headers["FOO"].must_equal "BAR"
    end

    it "should respond with a 200 to a subscribe" do
      client_id = "ABCD"

      # client always keeps a list of channels with last message id they got on each
      post "/message-bus/#{client_id}", {
        '/foo' => nil,
        '/bar' => nil
      }
      last_response.ok?.must_equal true
    end

    it "should correctly understand that -1 means stuff from now onwards" do

      @bus.publish('foo', 'bar')

      post "/message-bus/ABCD", {
        '/foo' => -1
      }
      last_response.ok?.must_equal true
      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
      parsed[0]["channel"].must_equal "/__status"
      parsed[0]["data"]["/foo"].must_equal@bus.last_id("/foo")

    end

    it "should respond with the data if messages exist in the backlog" do
      id =@bus.last_id('/foo')

      @bus.publish("/foo", "barbs")
      @bus.publish("/foo", "borbs")

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id,
        '/bar' => nil
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 2
      parsed[0]["data"].must_equal "barbs"
      parsed[1]["data"].must_equal "borbs"
    end

    it "should have no cross talk" do

      seq = 0
      @bus.site_id_lookup do
        (seq+=1).to_s
      end

      # published on channel 1
      msg = @bus.publish("/foo", "test")

      # subscribed on channel 2
      post "/message-bus/ABCD", {
        '/foo' => (msg-1)
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 0

    end

    it "should have global cross talk" do

      seq = 0
      @bus.site_id_lookup do
        (seq+=1).to_s
      end

      msg = @bus.publish("/global/foo", "test")

      post "/message-bus/ABCD", {
        '/global/foo' => (msg-1)
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
    end

    it "should not get consumed messages" do
      @bus.publish("/foo", "barbs")
      id =@bus.last_id('/foo')

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 0
    end

    it "should filter by user correctly" do
      id =@bus.publish("/foo", "test", user_ids: [1])
      @bus.user_id_lookup do |env|
        0
      end

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 0

      @bus.user_id_lookup do |env|
        1
      end

      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
    end

    it "should filter by group correctly" do
      id =@bus.publish("/foo", "test", group_ids: [3,4,5])
      @bus.group_ids_lookup do |env|
        [0,1,2]
      end

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 0

      @bus.group_ids_lookup do |env|
        [1,7,4,100]
      end

      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.must_equal 1
    end

    it "can decode a JSON encoded request" do
      id = @bus.last_id('/foo')
      @bus.publish("/foo", {json: true})
      post( "/message-bus/1234",
            JSON.generate({'/foo' => id}),
            { "CONTENT_TYPE" => "application/json" })
      JSON.parse(last_response.body).first["data"].must_equal({'json' => true})
    end

    describe "on_middleware_error handling" do
      it "allows error handling of middleware failures" do

        @bus.on_middleware_error do |env, err|
          if ArgumentError === err
            [407,{},[]]
          end
        end

        @bus.group_ids_lookup do |env|
          raise ArgumentError
        end

        post( "/message-bus/1234",
            JSON.generate({'/foo' => 1}),
            { "CONTENT_TYPE" => "application/json" })

        last_response.status.must_equal 407

      end
    end

    describe "messagebus.channels env support" do
      let(:extra_middleware) do
        Class.new do
          attr_reader :app

          def initialize(app)
            @app = app
          end

          def call(env)
            @app.call(env.merge('message_bus.channels'=>{'/foo'=>0}))
          end
        end
      end

      it "should respect messagebus.channels in the environment to force channels" do
        @message_bus_middleware = @async_middleware.app.app
        foo_id = @bus.publish("/foo", "testfoo")
        bar_id = @bus.publish("/bar", "testbar")

        post "/message-bus/ABCD", {
          '/foo' => foo_id - 1
        }

        parsed = JSON.parse(last_response.body)
        parsed.first['data'].must_equal 'testfoo'

        post "/message-bus/ABCD", {
          '/bar' => bar_id - 1
        }

        parsed = JSON.parse(last_response.body)
        parsed.first['data'].must_equal 'testfoo'
      end
    end
  end
end
