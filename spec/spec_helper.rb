$: << File.dirname(__FILE__)
require 'thin'
require 'lib/fake_async_middleware'

require 'minitest/autorun'
require 'minitest/spec'

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
