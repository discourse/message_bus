$: << File.dirname(__FILE__)
require 'thin'
require 'lib/fake_async_middleware'

require 'minitest/autorun'
require 'minitest/spec'

if ENV['MESSAGE_BUS_BACKEND'] == 'postgres'
  require 'message_bus/postgres/reliable_pub_sub'
  MESSAGE_BUS_REDIS_CONFIG = {:pub_sub_class=>MessageBus::Postgres::ReliablePubSub, :pg_config=>{:user=>'message_bus', :dbname=>'message_bus_test'}}
  PUB_SUB_CLASS = MessageBus::Postgres::ReliablePubSub
  PUB_SUB_CLASS.setup!(MESSAGE_BUS_REDIS_CONFIG)
else
  MESSAGE_BUS_REDIS_CONFIG = {}
  require 'message_bus/redis/reliable_pub_sub'
  PUB_SUB_CLASS = MessageBus::Redis::ReliablePubSub
end

def wait_for(timeout_milliseconds)
  timeout = (timeout_milliseconds + 0.0) / 1000
  finish = Time.now + timeout
  t = Thread.new do
    while Time.now < finish && !yield
      sleep(0.001)
    end
  end
  t.join
end
