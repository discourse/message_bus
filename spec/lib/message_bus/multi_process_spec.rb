require_relative '../../spec_helper'
require 'message_bus'

describe PUB_SUB_CLASS do

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

  it 'gets every response from child processes' do
    new_bus.reset!
    begin
      pids = (1..10).map{spawn_child}
      responses = []
      bus = new_bus
      Thread.new do
        bus.subscribe("/response", 0) do |msg|
          responses << msg if pids.include? msg.data.to_i
        end
      end
      10.times{bus.publish("/echo", Process.pid.to_s)}
      wait_for 4000 do
        responses.count == 100
      end

      # p responses.group_by(&:data).map{|k,v|[k, v.count]}
      # p responses.group_by(&:global_id).map{|k,v|[k, v.count]}
      responses.count.must_equal 100
    ensure
      if pids
        pids.each do |pid|
          Process.kill("KILL", pid)
          Process.wait(pid)
        end
      end
      bus.global_unsubscribe
    end
  end
end
