# frozen_string_literal: true

require_relative '../../spec_helper'
require 'message_bus'

describe BACKEND_CLASS do
  def self.error!
    @error = true
  end

  def self.error?
    defined?(@error)
  end

  def new_bus
    BACKEND_CLASS.new(test_config_for_backend(CURRENT_BACKEND).merge(db: 10))
  end

  def work_it
    bus = new_bus
    bus.subscribe("/echo", 0) do |msg|
      if msg.data == "done"
        bus.global_unsubscribe
      else
        bus.publish("/response", "#{msg.data}-#{Process.pid.to_s}")
      end
    end
  ensure
    bus.destroy
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
      bus = new_bus
      bus.reset!

      begin
        pids = (1..10).map { spawn_child }
        expected_responses = pids.map { |x| (0...10).map { |i| "0#{i}-#{x}" } }.flatten
        unexpected_responses = []

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

        wait_for(2000) do
          expected_responses.empty?
        end

        bus.publish("/echo", "done")
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
        bus.reset!
        bus.destroy
      end
    end
  end
end
