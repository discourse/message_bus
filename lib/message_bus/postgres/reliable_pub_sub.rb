require 'pg'

module MessageBus; end
module MessageBus::Postgres; end

class MessageBus::Postgres::RedisAPI
  CommandError = PGError

  class Listener
    attr_reader :do_sub, :do_unsub, :do_message

    def subscribe(&block)
      @do_sub = block
    end

    def unsubscribe(&block)
      @do_unsub = block
    end

    def message(&block)
      @do_message = block
    end
  end

  def self.setup!(config)
    new(config.merge(:no_prepare=>true)) do
      reset!
    end
  end

  def initialize(config)
    @config = config
    @listening_on = []
    @available = []
    @allocated = {}
    @mutex = Mutex.new
    @pid = Process.pid
    reconnect
  end

  def sync
    @mutex.synchronize{yield}
  end

  def hold
    if Process.pid != @pid
      reconnect
    end

    if conn = sync{@allocated[Thread.current]}
      return yield(conn)
    end
      
    begin
      if sync{@available.empty?}
        conn = @allocated[Thread.current] = new_pg_connection
        yield conn
      else
        conn = sync{@allocated[Thread.current] = @available.shift}
        yield conn
      end
    ensure
      sync{@available << conn} if conn
    end
  end

  def setup
    hold do |conn|
      conn.exec 'CREATE TABLE message_bus (id bigserial PRIMARY KEY, channel text NOT NULL, value text NOT NULL, added_at timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL)'
      conn.exec 'CREATE INDEX table_channel_id_index ON message_bus (channel, id)'
      conn.exec 'CREATE INDEX table_added_at_index ON message_bus (added_at)'
    end
    nil
  end

  def add(channel, value)
    hold{|conn| conn.exec_prepared('insert_message', [channel, value]).getvalue(0,0).to_i}
  end

  def clear_global_backlog(backlog_id, num_to_keep)
    if backlog_id > num_to_keep
      hold{|conn| conn.exec_prepared('clear_global_backlog', [backlog_id - num_to_keep])}
      nil
    end
  end

  def clear_channel_backlog(channel, backlog_id, num_to_keep)
    hold{|conn| conn.exec_prepared('clear_channel_backlog', [channel, backlog_id, num_to_keep])}
    nil
  end

  def backlog(channel, backlog_id)
    hold{|conn| conn.exec_prepared('channel_backlog', [channel, backlog_id]).values.each{|a| a[0] = a[0].to_i}}
  end

  def global_backlog(backlog_id)
    hold{|conn| conn.exec_prepared('global_backlog', [backlog_id]).values.each{|a| a[0] = a[0].to_i}}
  end

  def get_value(channel, id)
    hold{|conn| conn.exec_prepared('get_message', [channel, id]).getvalue(0,0)}
  end

  def new_pg_connection
    conn = PG::Connection.connect(@config[:pg_config] || {})
    unless @config[:no_prepare]
      conn.exec 'PREPARE insert_message AS INSERT INTO message_bus (channel, value) VALUES ($1, $2) RETURNING id'
      conn.exec 'PREPARE clear_global_backlog AS DELETE FROM message_bus WHERE (id <= $1)'
      conn.exec 'PREPARE clear_channel_backlog AS DELETE FROM message_bus WHERE ((channel = $1) AND (id <= (SELECT id FROM message_bus WHERE ((channel = $1) AND (id <= $2)) ORDER BY id DESC OFFSET $3)))'
      conn.exec 'PREPARE channel_backlog AS SELECT id, value FROM message_bus WHERE ((channel = $1) AND (id > $2)) ORDER BY id'
      conn.exec 'PREPARE global_backlog AS SELECT id, channel, value FROM message_bus WHERE (id > $1) ORDER BY id'
      conn.exec 'PREPARE get_message AS SELECT value FROM message_bus WHERE ((channel = $1) AND (id = $2))'
      conn.exec 'PREPARE max_channel_id AS SELECT max(id) FROM message_bus WHERE (channel = $1)'
      conn.exec 'PREPARE max_id AS SELECT max(id) FROM message_bus'
      conn.exec 'PREPARE publish AS SELECT pg_notify($1, $2)'
    end
    conn
  end

  def reconnect
    @listening_on.clear
    sync do
      @available.clear
    end
  end

  def flushall
    hold{|conn| conn.exec 'DROP TABLE IF EXISTS message_bus'}
    setup
  end
  alias flushdb flushall
  alias reset! flushall

  def client
    self
  end

  def max_id(channel=nil)
    res = if channel
      hold{|conn| conn.exec_prepared('max_channel_id', [channel])}
    else
      hold{|conn| conn.exec_prepared('max_id')}
    end

    if res.ntuples > 0
      res.getvalue(0,0).to_i
    else
      0
    end
  end

  def publish(channel, data)
    hold{|conn| conn.exec_prepared('publish', [channel, data])}
  end

  def subscribe(channel)
    @listening_on << channel
    listener = Listener.new
    yield listener
    
    hold do |conn|
      begin
        conn.exec "LISTEN #{channel}"
        listener.do_sub.call
        while listening_on?(channel)
          conn.wait_for_notify(10) do |_,_,payload|
            listener.do_message.call(nil, payload)
          end
        end
        listener.do_unsub.call
      ensure
        begin
          conn.exec "UNLISTEN #{channel}"
        rescue PGError, IOError
        end
      end
    end
  end

  def unsubscribe
    @listening_on.clear
  end

  private

  def listening_on?(channel)
    @listening_on.include?(channel)
  end
end

class MessageBus::Postgres::ReliablePubSub
  attr_reader :subscribed
  attr_accessor :max_publish_retries, :max_publish_wait, :max_backlog_size,
                :max_global_backlog_size, :max_in_memory_publish_backlog,
                :max_backlog_age

  UNSUB_MESSAGE = "$$UNSUBSCRIBE"

  def self.setup!(config)
    MessageBus::Postgres::RedisAPI.setup!(config)
  end

  # max_backlog_size is per multiplexed channel
  def initialize(redis_config = {}, max_backlog_size = 1000)
    @redis_config = redis_config
    @max_backlog_size = max_backlog_size
    @max_global_backlog_size = 2000
    @max_publish_retries = 10
    @max_publish_wait = 500 #ms
    @max_in_memory_publish_backlog = 1000
    @in_memory_backlog = []
    @lock = Mutex.new
    @flush_backlog_thread = nil
    # after 7 days inactive backlogs will be removed
    @max_backlog_age = 604800
    @h = {}
  end

  def new_redis_connection
    MessageBus::Postgres::RedisAPI.new(@redis_config)
  end

  def backend
    :postgres
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

  # use with extreme care, will nuke all of the data
  def reset!
    pub_redis.reset!
  end

  def publish(channel, data, queue_in_memory=true)
    redis = pub_redis
    backlog_id = redis.add(channel, data)
    msg = MessageBus::Message.new backlog_id, backlog_id, channel, data
    payload = msg.encode
    redis.publish redis_channel_name, payload
    redis.clear_global_backlog(backlog_id, @max_global_backlog_size)
    redis.clear_channel_backlog(channel, backlog_id, @max_backlog_size)

    backlog_id

  rescue redis.class::CommandError => e
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
    while true
      try_again = false

      @lock.synchronize do
        break if @in_memory_backlog.length == 0

        begin
          publish(*@in_memory_backlog[0],false)
        rescue pub_redis.class::CommandError => e
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

      if try_again
        sleep 0.005
        # in case we are not connected to the correct server
        # which can happen when sharing ips
        pub_redis.client.reconnect
      end
    end
  ensure
    @lock.synchronize do
      @flush_backlog_thread = nil
    end
  end

  def last_id(channel)
    pub_redis.max_id(channel)
  end

  def backlog(channel, last_id = nil)
    redis = pub_redis
    items = redis.backlog channel, last_id.to_i

    items.map! do |id, data|
      MessageBus::Message.new id, id, channel, data
    end
  end

  def global_backlog(last_id = nil)
    last_id = last_id.to_i
    redis = pub_redis

    items = redis.global_backlog last_id.to_i

    items.map! do |id, channel, data|
      MessageBus::Message.new id, id, channel, data
    end
  end

  def get_message(channel, message_id)
    redis = pub_redis

    if data = redis.get_value(channel, message_id)
      MessageBus::Message.new message_id, message_id, channel, data
    else
      nil
    end
  end

  def subscribe(channel, last_id = nil)
    # trivial implementation for now,
    #   can cut down on connections if we only have one global subscriber
    raise ArgumentError unless block_given?

    global_subscribe(last_id) do |m|
      yield m if m.channel == channel
    end
  end

  def process_global_backlog(highest_id)
    if highest_id > pub_redis.max_id
      highest_id = 0
    end

    global_backlog(highest_id).each do |old|
      yield old
      highest_id = old.global_id
    end

    highest_id
  end

  def global_unsubscribe
    if @redis_global
      pub_redis.publish(redis_channel_name, UNSUB_MESSAGE)
      @redis_global.reconnect
      @redis_global = nil
    end
  end

  def global_subscribe(last_id=nil, &blk)
    raise ArgumentError unless block_given?
    highest_id = last_id


    begin
      redis_global = @redis_global = new_redis_connection

      if highest_id
        highest_id = process_global_backlog(highest_id, &blk)
      end

      redis_global.subscribe(redis_channel_name) do |on|
        h = {}

        on.subscribe do
          if highest_id
            highest_id = process_global_backlog(highest_id) do |m|
              h[m.global_id] = true
              yield m
            end
          end
          h = nil if h.empty?
          @subscribed = true
        end

        on.unsubscribe do
          @subscribed = false
        end

        on.message do |c,m|
          if m == UNSUB_MESSAGE
            redis_global.unsubscribe
            return
          end
          m = MessageBus::Message.decode m

          # we have 3 options
          #
          # 1. message came in the correct order GREAT, just deal with it
          # 2. message came in the incorrect order COMPLICATED, wait a tiny bit and clear backlog
          # 3. message came in the incorrect order and is lowest than current highest id, reset

          if h
            # If already yielded during the clear backlog when subscribing,
            # don't yield a duplicate copy.
            unless h.delete(m.global_id)
              # First new message not from clear backlog, disable further checking.
              h = nil if h.empty?
              yield m
            end
          else
            yield m
          end
        end
      end
    rescue => error
      MessageBus.logger.warn "#{error} subscribe failed, reconnecting in 1 second. Call stack #{error.backtrace}"
      sleep 1
      retry
    end
  end

end
