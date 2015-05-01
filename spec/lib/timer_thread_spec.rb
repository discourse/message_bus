require 'spec_helper'
require 'message_bus/timer_thread'

describe MessageBus::TimerThread do
  before do
    @timer = MessageBus::TimerThread.new
  end

  after do
    @timer.stop
  end

  it "allows you to cancel timers" do
    success = true
    @timer.queue(0.005){success=false}.cancel
    sleep(0.006)
    success.should == true
  end

  it "queues jobs in the correct order" do
    counter = 0
    failed = nil

    items = (0..5).to_a.shuffle
    items.map do |i|
      # threading introduces a delay meaning we need to wait a long time
      Thread.new do
        @timer.queue(i/5.0) do
          failed = true if counter != i
          counter += 1
        end
      end
    end

    wait_for(1500) {
      counter == items.length
    }

    counter.should == items.length
    failed.should == nil
  end

  it "should call the error callback if something goes wrong" do
    error = nil

    @timer.queue do
      boom
    end

    @timer.on_error do |e|
      error = e
    end

    @timer.queue do
      boom
    end

    wait_for(10) do
      error
    end

    error.class.should == NameError
  end

end
