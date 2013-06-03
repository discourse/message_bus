require 'spec_helper'
require 'message_bus'
require 'redis'


describe MessageBus do

  before do
    @bus = MessageBus::Instance.new
    @bus.site_id_lookup do
      "magic"
    end
    @bus.redis_config = {}
  end

  after do
    @bus.destroy
  end

  it "should automatically decode hashed messages" do
    data = nil
    @bus.subscribe("/chuck") do |msg|
      data = msg.data
    end
    @bus.publish("/chuck", {:norris => true})
    wait_for(2000){ data }

    data["norris"].should == true
  end

  it "should get a message if it subscribes to it" do
    user_ids,data,site_id,channel = nil

    @bus.subscribe("/chuck") do |msg|
      data = msg.data
      site_id = msg.site_id
      channel = msg.channel
      user_ids = msg.user_ids
    end

    @bus.publish("/chuck", "norris", user_ids: [1,2,3])

    wait_for(2000){data}

    data.should == 'norris'
    site_id.should == 'magic'
    channel.should == '/chuck'
    user_ids.should == [1,2,3]

  end


  it "should get global messages if it subscribes to them" do
    data,site_id,channel = nil

    @bus.subscribe do |msg|
      data = msg.data
      site_id = msg.site_id
      channel = msg.channel
    end

    @bus.publish("/chuck", "norris")

    wait_for(2000){data}

    data.should == 'norris'
    site_id.should == 'magic'
    channel.should == '/chuck'

  end

  it "should have the ability to grab the backlog messages in the correct order" do
    id = @bus.publish("/chuck", "norris")
    @bus.publish("/chuck", "foo")
    @bus.publish("/chuck", "bar")

    r = @bus.backlog("/chuck", id)

    r.map{|i| i.data}.to_a.should == ['foo', 'bar']
  end


  it "should support forking properly do" do
    data = nil
    @bus.subscribe do |msg|
      data = msg.data
    end

    @bus.publish("/hello", "world")
    wait_for(2000){ data }

    if child = Process.fork
      wait_for(2000) { data == "ready" }
      @bus.publish("/hello", "world1")
      wait_for(2000) { data == "got it" }
      data.should == "got it"
      Process.wait(child)
    else
      @bus.after_fork
      @bus.publish("/hello", "ready")
      wait_for(2000) { data == "world1" }
      if(data=="world1")
        @bus.publish("/hello", "got it")
      end

      $stdout.reopen("/dev/null", "w")
      $stderr.reopen("/dev/null", "w")
      exit
    end

  end

end
