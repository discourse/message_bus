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
    PUB_SUB_CLASS.new(MESSAGE_BUS_CONFIG.merge(db: 10))
  end

  def work_it
    bus = new_bus
    $stdout.reopen("/dev/null", "w")
    $stderr.reopen("/dev/null", "w")
    # subscribe blocks, so we need a new bus to transmit
    new_bus.subscribe("/echo", 0) do |msg|
      bus.publish("/response", "#{msg.data}-#{Process.pid.to_s}")
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
      test_never :memory
      skip("previous error") if self.class.error?
      GC.start
      new_bus.reset!
      begin
        pids = (1..10).map { spawn_child }
        expected_responses = pids.map { |x| (0...10).map { |i| "0#{i}-#{x}" } }.flatten
        unexpected_responses = []
        bus = new_bus
        t = Thread.new do
          bus.subscribe("/response", 0) do |msg|
            if expected_responses.include?(msg.data)
              expected_responses.delete(msg.data)
            else
              unexpected_responses << msg.data
            end
          end
        end
        10.times { |i| bus.publish("/echo", "0#{i}") }
        wait_for 4000 do
          expected_responses.empty?
        end
        bus.global_unsubscribe
        t.join

        expected_responses.must_be :empty?
        unexpected_responses.must_be :empty?
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
