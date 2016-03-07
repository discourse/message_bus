require 'redis'
# the heart of the message bus, it acts as 2 things
#
# 1. A channel multiplexer
# 2. Backlog storage per-multiplexed channel.
#
# ids are all sequencially increasing numbers starting at 0
#

module MessageBus::Redis; end
class MessageBus::Redis::ReliablePubSub
  attr_reader :subscribed
  attr_accessor :max_backlog_size, :max_global_backlog_size, :max_in_memory_publish_backlog, :max_backlog_age

  UNSUB_MESSAGE = "$$UNSUBSCRIBE"

  class NoMoreRetries < StandardError; end
  class BackLogOutOfOrder < StandardError
    attr_accessor :highest_id

    def initialize(highest_id)
      @highest_id = highest_id
    end
  end

  # max_backlog_size is per multiplexed channel
  def initialize(redis_config = {}, max_backlog_size = 1000)
    @redis_config = redis_config.dup
    unless @redis_config[:enable_redis_logger]
      @redis_config[:logger] = nil
    end
    @max_backlog_size = max_backlog_size
    @max_global_backlog_size = 2000
    @max_in_memory_publish_backlog = 1000
    @in_memory_backlog = []
    @lock = Mutex.new
    @flush_backlog_thread = nil
    # after 7 days inactive backlogs will be removed
    @max_backlog_age = 604800
  end

  def new_redis_connection
    ::Redis.new(@redis_config)
  end

  def after_fork
    pub_redis.client.reconnect
  end

  def redis_channel_name
    db = @redis_config[:db] || 0
    "_message_bus_#{db}"
  end

  # redis connection used for publishing messages
  def pub_redis
    @pub_redis ||= new_redis_connection
  end

  def backlog_key(channel)
    "__mb_backlog_n_#{channel}"
  end

  def backlog_id_key(channel)
    "__mb_backlog_id_n_#{channel}"
  end

  def global_id_key
    "__mb_global_id_n"
  end

  def global_backlog_key
    "__mb_global_backlog_n"
  end

  # use with extreme care, will nuke all of the data
  def reset!
    pub_redis.keys("__mb_*").each do |k|
      pub_redis.del k
    end
  end

  def publish(channel, data, queue_in_memory=true)
    redis = pub_redis
    backlog_id_key = backlog_id_key(channel)
    backlog_key = backlog_key(channel)

    global_id = nil
    backlog_id = nil

    redis.multi do |m|
      global_id = m.incr(global_id_key)
      backlog_id = m.incr(backlog_id_key)
    end

    global_id = global_id.value
    backlog_id = backlog_id.value

    msg = MessageBus::Message.new global_id, backlog_id, channel, data
    payload = msg.encode

    redis.multi do |m|

      redis.zadd backlog_key, backlog_id, payload
      redis.expire backlog_key, @max_backlog_age

      redis.zadd global_backlog_key, global_id, backlog_id.to_s << "|" << channel
      redis.expire global_backlog_key, @max_backlog_age

      redis.publish redis_channel_name, payload

      if backlog_id > @max_backlog_size
        redis.zremrangebyscore backlog_key, 1, backlog_id - @max_backlog_size
      end

      if global_id > @max_global_backlog_size
        redis.zremrangebyscore global_backlog_key, 1, global_id - @max_global_backlog_size
      end

    end

    backlog_id

  rescue Redis::CommandError => e
    if queue_in_memory &&
          e.message =~ /^READONLY/

      @lock.synchronize do
        @in_memory_backlog << [channel,data]
        if @in_memory_backlog.length > @max_in_memory_publish_backlog
          @in_memory_backlog.delete_at(0)
          MessageBus.logger.warn("Dropping old message cause max_in_memory_publish_backlog is full")
        end
      end

      if @flush_backlog_thread == nil
        @lock.synchronize do
          if @flush_backlog_thread == nil
            @flush_backlog_thread = Thread.new{ensure_backlog_flushed}
          end
        end
      end
      nil
    else
      raise
    end
  end

  def ensure_backlog_flushed
    flushed = false

    while !flushed
      try_again = false

      if is_readonly?
        sleep 1
        next
      end

      @lock.synchronize do
        if @in_memory_backlog.length == 0
          flushed = true
          break
        end

        begin
          publish(*@in_memory_backlog[0],false)
        rescue Redis::CommandError => e
          if e.message =~ /^READONLY/
            try_again = true
          else
            MessageBus.logger.warn("Dropping undeliverable message #{e}")
          end
        rescue => e
          MessageBus.logger.warn("Dropping undeliverable message #{e}")
        end

        @in_memory_backlog.delete_at(0) unless try_again
      end
    end
  ensure
    @lock.synchronize do
      @flush_backlog_thread = nil
    end
  end

  def last_id(channel)
    backlog_id_key = backlog_id_key(channel)
    pub_redis.get(backlog_id_key).to_i
  end

  def backlog(channel, last_id = nil)
    redis = pub_redis
    backlog_key = backlog_key(channel)
    items = redis.zrangebyscore backlog_key, last_id.to_i + 1, "+inf"

    items.map do |i|
      MessageBus::Message.decode(i)
    end
  end

  def global_backlog(last_id = nil)
    last_id = last_id.to_i
    redis = pub_redis

    items = redis.zrangebyscore global_backlog_key, last_id.to_i + 1, "+inf"

    items.map! do |i|
      pipe = i.index "|"
      message_id = i[0..pipe].to_i
      channel = i[pipe+1..-1]
      m = get_message(channel, message_id)
      m
    end

    items.compact!
    items
  end

  def get_message(channel, message_id)
    redis = pub_redis
    backlog_key = backlog_key(channel)

    items = redis.zrangebyscore backlog_key, message_id, message_id
    if items && items[0]
      MessageBus::Message.decode(items[0])
    else
      nil
    end
  end

  def subscribe(channel, last_id = nil)
    # trivial implementation for now,
    #   can cut down on connections if we only have one global subscriber
    raise ArgumentError unless block_given?

    if last_id
      # we need to translate this to a global id, at least give it a shot
      #   we are subscribing on global and global is always going to be bigger than local
      #   so worst case is a replay of a few messages
      message = get_message(channel, last_id)
      if message
        last_id = message.global_id
      end
    end
    global_subscribe(last_id) do |m|
      yield m if m.channel == channel
    end
  end

  def process_global_backlog(highest_id, raise_error, &blk)
    if highest_id > pub_redis.get(global_id_key).to_i
      highest_id = 0
    end

    global_backlog(highest_id).each do |old|
      if highest_id + 1 == old.global_id
        yield old
        highest_id = old.global_id
      else
        raise BackLogOutOfOrder.new(highest_id) if raise_error
        if old.global_id > highest_id
          yield old
          highest_id = old.global_id
        end
      end
    end

    highest_id
  end

  def global_unsubscribe
    if @redis_global
      pub_redis.publish(redis_channel_name, UNSUB_MESSAGE)
      @redis_global.disconnect
      @redis_global = nil
    end
  end

  def global_subscribe(last_id=nil, &blk)
    raise ArgumentError unless block_given?
    highest_id = last_id

    clear_backlog = lambda do
      retries = 4
      begin
        highest_id = process_global_backlog(highest_id, retries > 0, &blk)
      rescue BackLogOutOfOrder => e
        highest_id = e.highest_id
        retries -= 1
        sleep(rand(50) / 1000.0)
        retry
      end
    end


    begin
      @redis_global = new_redis_connection

      if highest_id
        clear_backlog.call(&blk)
      end

      @redis_global.subscribe(redis_channel_name) do |on|
        on.subscribe do
          if highest_id
            clear_backlog.call(&blk)
          end
          @subscribed = true
        end

        on.unsubscribe do
          @subscribed = false
        end

        on.message do |c,m|
          if m == UNSUB_MESSAGE
            @redis_global.unsubscribe
            return
          end
          m = MessageBus::Message.decode m

          # we have 3 options
          #
          # 1. message came in the correct order GREAT, just deal with it
          # 2. message came in the incorrect order COMPLICATED, wait a tiny bit and clear backlog
          # 3. message came in the incorrect order and is lowest than current highest id, reset

          if highest_id.nil? || m.global_id == highest_id + 1
            highest_id = m.global_id
            yield m
          else
            clear_backlog.call(&blk)
          end
        end
      end
    rescue => error
      MessageBus.logger.warn "#{error} subscribe failed, reconnecting in 1 second. Call stack #{error.backtrace}"
      sleep 1
      retry
    end
  end

  private

  def is_readonly?
    key = "__mb_is_readonly".freeze

    begin
      # in case we are not connected to the correct server
      # which can happen when sharing ips
      pub_redis.client.reconnect
      pub_redis.client.call([:set, key, '1'])
      false
    rescue Redis::CommandError => e
      return true if e.message =~ /^READONLY/
    end
  end

  MessageBus::BACKENDS[:redis] = self
end
