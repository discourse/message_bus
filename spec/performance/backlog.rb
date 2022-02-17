# frozen_string_literal: true

$LOAD_PATH << File.join(File.dirname(__FILE__), '..', '..', 'lib')
require 'logger'
require 'benchmark'
require 'message_bus'

require_relative "../helpers"

backends = ENV['MESSAGE_BUS_BACKENDS'].split(",").map(&:to_sym)
channel = "/foo"
iterations = 10_000
results = []

puts "Running backlog benchmark with #{iterations} iterations on backends: #{backends.inspect}"

run_benchmark = lambda do |bm, backend|
  bus = MessageBus::Instance.new
  bus.configure(test_config_for_backend(backend))

  bus.backend_instance.max_backlog_size = 100
  bus.backend_instance.max_global_backlog_size = 1000

  channel_names = 10.times.map { |i| "channel#{i}" }

  100.times do |i|
    channel_names.each do |ch|
      bus.publish(ch, { message_number_is: i })
    end
  end

  last_ids = channel_names.map { |ch| [ch, bus.last_id(ch)] }.to_h

  1000.times do
    # Warmup
    client = MessageBus::Client.new(message_bus: bus)
    channel_names.each { |ch| client.subscribe(ch, -1) }
    client.backlog
  end

  bm.report("#{backend} - #backlog with no backlogs requested") do
    iterations.times do
      client = MessageBus::Client.new(message_bus: bus)
      channel_names.each { |ch| client.subscribe(ch, -1) }
      client.backlog
    end
  end

  (0..5).each do |ch_i|
    channels_with_messages = (ch_i) * 2

    bm.report("#{backend} - #backlog when #{channels_with_messages}/10 channels have new messages") do
      iterations.times do
        client = MessageBus::Client.new(message_bus: bus)
        channel_names.each_with_index do |ch, i|
          client.subscribe(ch, last_ids[ch] + ((i < channels_with_messages) ? -1 : 0))
        end
        result = client.backlog
        if result.length != channels_with_messages
          raise "Result has #{result.length} messages. Expected #{channels_with_messages}"
        end
      end
    end
  end

  bus.reset!
  bus.destroy
end

puts

Benchmark.benchmark("     duration\n", 60, "%10.2rs\n", "") do |bm|
  backends.each do |backend|
    run_benchmark.call(bm, backend)
  end
end
puts
results.each do |result|
  puts result
end
