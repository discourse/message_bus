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
    counter = 0
    failed = nil

    ready = 0

    items = (0...4).to_a.shuffle
    items.map do |i|
      # threading introduces a delay meaning we need to wait a long time
      Thread.new do
        ready += 1
        while ready < 4
          sleep 0
        end
        # on my mbp I measure at least 200ms of schedule jitter for Thread
        @timer.queue(i/3.0) do
          #puts "counter #{counter} i #{i}"
          failed = true if counter != i
          counter += 1
        end
        #puts "\nqueued #{i/200.0} #{i} #{Time.now.to_f}\n"
      end
    end

    wait_for(3000) {
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
