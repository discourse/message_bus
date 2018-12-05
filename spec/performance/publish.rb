$LOAD_PATH << File.join(File.dirname(__FILE__), '..', '..', 'lib')
require 'logger'
require 'benchmark'
require 'message_bus'

require_relative "../helpers"

backends = ENV['MESSAGE_BUS_BACKENDS'].split(",").map(&:to_sym)
channel = "/foo"
iterations = 10_000
results = []

puts "Running publication benchmark with #{iterations} iterations on backends: #{backends.inspect}"

puts
Benchmark.bm(10) do |bm|
  backends.each do |backend|
    messages_received = 0

    bus = MessageBus::Instance.new
    bus.configure(test_config_for_backend(backend))

    bus.after_fork
    bus.subscribe(channel) do |_message|
      messages_received += 1
    end

    bm.report(backend) do
      iterations.times { bus.publish(channel, "Hello world") }
      wait_for(2000) { messages_received == iterations }
    end

    results << "[#{backend}]: #{iterations} messages sent, #{messages_received} received, rate of #{(messages_received.to_f / iterations.to_f) * 100}%"

    bus.reset!
    bus.destroy
  end
end
puts

results.each do |result|
  puts result
end
