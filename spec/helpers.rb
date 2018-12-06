def wait_for(timeout_milliseconds = 2000)
  timeout = (timeout_milliseconds + 0.0) / 1000
  finish = Time.now + timeout

  Thread.new do
    sleep(0.001) while Time.now < finish && !yield
  end.join
end

def test_config_for_backend(backend)
  config = { backend: backend }
  case backend
  when :redis
    config[:url] = ENV['REDISURL']
  when :postgres
    config[:backend_options] = { host: ENV['PGHOST'], user: ENV['PGUSER'] || ENV['USER'], password: ENV['PGPASSWORD'], dbname: ENV['PGDATABASE'] || 'message_bus_test' }
  end
  config
end
