require_relative '../../spec_helper'
require 'message_bus'

describe PUB_SUB_CLASS do
  def self.error!
    @error = true
  end

  def self.error?
    defined?(@error)
  end

  def new_bus
    PUB_SUB_CLASS.new(MESSAGE_BUS_REDIS_CONFIG.merge(:db => 10))
  end

  def work_it
    bus = new_bus
    $stdout.reopen("/dev/null", "w")
    $stderr.reopen("/dev/null", "w")
    # subscribe blocks, so we need a new bus to transmit
    new_bus.subscribe("/echo", 0) do |msg|
      bus.publish("/response", Process.pid.to_s)
    end
  ensure
    exit!(0)
  end

  def spawn_child
    r = fork
    if r.nil?
      work_it
    else
      r
    end
  end

  n = ENV['MULTI_PROCESS_TIMES'].to_i
  n = 1 if n < 1
  n.times do 
    it 'gets every response from child processes' do
      skip("previous error") if self.class.error?
      GC.start
      new_bus.reset!
      begin
        pids = (1..10).map{spawn_child}
        responses = []
        bus = new_bus
        t = Thread.new do
          bus.subscribe("/response", 0) do |msg|
            responses << msg if pids.include? msg.data.to_i
          end
        end
        # Sleep, as not all children may be listening immediately
        sleep 0.1
        10.times{bus.publish("/echo", Process.pid.to_s)}
        wait_for 4000 do
          responses.count == 100
        end
        bus.global_unsubscribe
        t.join

        # p responses.group_by(&:data).map{|k,v|[k, v.count]}
        # p responses.group_by(&:global_id).map{|k,v|[k, v.count]}
        responses.count.must_equal 100
      rescue Exception
        self.class.error!
        raise
      ensure
        if pids
          pids.each do |pid|
            begin
              Process.kill("KILL", pid)
            rescue SystemCallError
            end
            Process.wait(pid)
          end
        end
        bus.global_unsubscribe
      end
    end
  end
end
