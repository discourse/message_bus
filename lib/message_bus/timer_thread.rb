# frozen_string_literal: true

class MessageBus::TimerThread
  attr_reader :jobs

  class Cancelable
    class NoOp
      def call
      end
    end

    # usually you could just use a blank lambda
    # but an object is ever so slightly faster
    NOOP = NoOp.new

    def initialize(job)
      @job = job
    end

    def cancel
      @job[1] = NOOP
    end
  end

  class CancelableEvery
    attr_accessor :cancelled, :current
    def cancel
      current.cancel if current
      @cancelled = true
    end
  end

  def initialize
    @stopped = false
    @jobs = []
    @mutex = Mutex.new
    @next = nil
    @thread = Thread.new { do_work }
    @on_error = lambda { |e| STDERR.puts "Exception while processing Timer:\n #{e.backtrace.join("\n")}" }
  end

  def stop
    @stopped = true
    running = true
    while running
      @mutex.synchronize do
        running = @thread && @thread.alive?
        @thread.wakeup if running
      end
      sleep 0
    end
  end

  def every(delay, &block)
    result = CancelableEvery.new
    do_work = proc do
      begin
        block.call
      ensure
        result.current = queue(delay, &do_work)
      end
    end
    result.current = queue(delay, &do_work)
    result
  end

  # queue a block to run after a certain delay (in seconds)
  def queue(delay = 0, &block)
    queue_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay
    job = [queue_time, block]

    @mutex.synchronize do
      i = @jobs.length
      while i > 0
        i -= 1
        current, _ = @jobs[i]
        if current < queue_time
          i += 1
          break
        end
      end
      @jobs.insert(i, job)
      @next = queue_time if i == 0
    end

    unless @thread.alive?
      @mutex.synchronize do
        @thread = Thread.new { do_work } unless @thread.alive?
      end
    end

    if @thread.status == "sleep"
      @thread.wakeup
    end

    Cancelable.new(job)
  end

  def on_error(&block)
    @on_error = block
  end

  protected

  def do_work
    while !@stopped
      if @next && @next <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _, blk = @mutex.synchronize { @jobs.shift }
        begin
          blk.call
        rescue => e
          @on_error.call(e) if @on_error
        end
        @mutex.synchronize do
          @next, _ = @jobs[0]
        end
      end
      unless @next && @next <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep_time = 1000
        @mutex.synchronize do
          sleep_time = @next - Process.clock_gettime(Process::CLOCK_MONOTONIC) if @next
        end
        sleep [0, sleep_time].max
      end
    end
  end
end
