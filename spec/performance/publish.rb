# frozen_string_literal: true

$LOAD_PATH << File.join(File.dirname(__FILE__), '..', '..', 'lib')
require 'logger'
require 'benchmark'
require 'message_bus'

require_relative "../helpers"

backends = ENV['MESSAGE_BUS_BACKENDS'].split(",").map(&:to_sym)
channel = "/foo"
iterations = 100_000
results = []

puts "Running publication benchmark with #{iterations} iterations on backends: #{backends.inspect}"

benchmark_publication_only = lambda do |bm, backend|
  bus = MessageBus::Instance.new
  bus.configure(test_config_for_backend(backend))

  bm.report("#{backend} - publication only") do
    iterations.times { bus.publish(channel, "Hello world") }
  end

  bus.reset!
  bus.destroy
end

benchmark_subscription_no_trimming = lambda do |bm, backend|
  test_title = "#{backend} - subscription no trimming"

  bus = MessageBus::Instance.new
  bus.configure(test_config_for_backend(backend))

  bus.backend_instance.max_backlog_size = iterations
  bus.backend_instance.max_global_backlog_size = iterations

  messages_received = 0
  bus.after_fork
  bus.subscribe(channel) do |_message|
    messages_received += 1
  end

  bm.report(test_title) do
    iterations.times { bus.publish(channel, "Hello world") }
    wait_for(60000) { messages_received == iterations }
  end

  results << "[#{test_title}]: #{iterations} messages sent, #{messages_received} received, rate of #{(messages_received.to_f / iterations.to_f) * 100}%"

  bus.reset!
  bus.destroy
end

benchmark_subscription_with_trimming = lambda do |bm, backend|
  test_title = "#{backend} - subscription with trimming"

  bus = MessageBus::Instance.new
  bus.configure(test_config_for_backend(backend))

  bus.backend_instance.max_backlog_size = (iterations / 10)
  bus.backend_instance.max_global_backlog_size = (iterations / 10)

  messages_received = 0
  bus.after_fork
  bus.subscribe(channel) do |_message|
    messages_received += 1
  end

  bm.report(test_title) do
    iterations.times { bus.publish(channel, "Hello world") }
    wait_for(60000) { messages_received == iterations }
  end

  results << "[#{test_title}]: #{iterations} messages sent, #{messages_received} received, rate of #{(messages_received.to_f / iterations.to_f) * 100}%"

  bus.reset!
  bus.destroy
end

benchmark_subscription_with_trimming_and_clear_every = lambda do |bm, backend|
  test_title = "#{backend} - subscription with trimming and clear_every=50"

  bus = MessageBus::Instance.new
  bus.configure(test_config_for_backend(backend))

  bus.backend_instance.max_backlog_size = (iterations / 10)
  bus.backend_instance.max_global_backlog_size = (iterations / 10)
  bus.backend_instance.clear_every = 50

  messages_received = 0
  bus.after_fork
  bus.subscribe(channel) do |_message|
    messages_received += 1
  end

  bm.report(test_title) do
    iterations.times { bus.publish(channel, "Hello world") }
    wait_for(60000) { messages_received == iterations }
  end

  results << "[#{test_title}]: #{iterations} messages sent, #{messages_received} received, rate of #{(messages_received.to_f / iterations.to_f) * 100}%"

  bus.reset!
  bus.destroy
end

puts
Benchmark.bm(60) do |bm|
  backends.each do |backend|
    benchmark_publication_only.call(bm, backend)
  end

  puts

  backends.each do |backend|
    benchmark_subscription_no_trimming.call(bm, backend)
  end

  results << nil
  puts

  backends.each do |backend|
    benchmark_subscription_with_trimming.call(bm, backend)
  end

  backends.each do |backend|
    benchmark_subscription_with_trimming_and_clear_every.call(bm, backend)
  end
end
puts

results.each do |result|
  puts result
end
