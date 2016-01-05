require 'spec_helper'
require 'message_bus/timer_thread'

describe MessageBus::TimerThread do
  before do
    @timer = MessageBus::TimerThread.new
  end

  after do
    @timer.stop
  end

  it "allows you to queue every jobs" do
    i = 0
    m = Mutex.new
    every = @timer.every(0.001){m.synchronize{i += 1}}
    # allow lots of time, cause in test mode stuff can be slow
    wait_for(1000) do
      m.synchronize do
        every.cancel if i == 3
        i == 3
      end
    end
    sleep 0.002
    i.should == 3
  end

  it "allows you to cancel timers" do
    success = true
    @timer.queue(0.005){success=false}.cancel
    sleep(0.006)
    success.should == true
  end

  it "queues jobs in the correct order" do

    results = []
    (0..3).to_a.reverse.each do |i|
      @timer.queue(0.005 * i) do
        results << i
      end
    end

    wait_for(3000) {
      4 == results.length
    }

    results.should == [0,1,2,3]
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
