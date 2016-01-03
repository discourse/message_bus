require 'http/parser'
class FakeAsyncMiddleware

  def initialize(app,config={})
    @app = app
    @bus = config[:message_bus] || MessageBus
    @simulate_thin_async = false
    @simulate_hijack = false
    @in_async = false
  end

  def app
    @app
  end

  def simulate_thin_async
    @simulate_thin_async = true
    @simulate_hijack = false
  end

  def simulate_hijack
    @simulate_thin_async = false
    @simulate_hijack = true
  end

  def allow_chunked
    @allow_chunked = true
  end

  def in_async?
    @in_async
  end


  def simulate_thin_async?
    @simulate_thin_async && @bus.long_polling_enabled?
  end

  def simulate_hijack?
    @simulate_hijack && @bus.long_polling_enabled?
  end

  def call(env)
    unless @allow_chunked
      env['HTTP_DONT_CHUNK'] = 'True'
    end
    if simulate_thin_async?
      call_thin_async(env)
    elsif simulate_hijack?
      call_rack_hijack(env)
    else
      @app.call(env)
    end
  end

  def translate_io_result(io)
    data = io.string
    body = ""

    parser = Http::Parser.new
    parser.on_body = proc { |chunk| body << chunk }
    parser << data

    [parser.status_code, parser.headers, [body]]
  end


  def call_rack_hijack(env)
    # this is not to spec, the spec actually return, but here we will simply simulate and block
    result = nil
    hijacked = false
    io = nil

    EM.run {
      env['rack.hijack'] = lambda {
        hijacked = true
        io = StringIO.new
      }

      env['rack.hijack_io'] = io

      result = @app.call(env)

      EM::Timer.new(1) { EM.stop }

      defer = lambda {
        if !io || !io.closed?
          @in_async = true
          EM.next_tick do
            defer.call
          end
        else
          if io.closed?
            result = translate_io_result(io)
          end
          EM.next_tick { EM.stop }
        end
      }

      if !hijacked
        EM.next_tick { EM.stop }
      else
        defer.call
      end
    }

    @in_async = false
    result || [500, {}, ['timeout']]

  end

  def call_thin_async(env)
    result = nil
    EM.run {
      env['async.callback'] = lambda { |r|
        # more judo with deferrable body, at this point we just have headers
        r[2].callback do
          # even more judo cause rack test does not call each like the spec says
          body = ""
          r[2].each do |m|
            body << m
          end
          r[2] = [body]
          result = r
        end
      }
      catch(:async) {
        result = @app.call(env)
      }

      EM::Timer.new(1) { EM.stop }

      defer = lambda {
        if !result
          @in_async = true
          EM.next_tick do
            defer.call
          end
        else
          EM.next_tick { EM.stop }
        end
      }
      defer.call
    }

    @in_async = false
    result || [500, {}, ['timeout']]
  end
end

