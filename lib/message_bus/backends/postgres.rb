require 'pg'

module MessageBus::Postgres; end

class MessageBus::Postgres::Client
  INHERITED_CONNECTIONS = []

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

  def initialize(config)
    @config = config
    @listening_on = {}
    @available = []
    @allocated = {}
    @mutex = Mutex.new
    @pid = Process.pid
  end

  def add(channel, value)
    hold{|conn| exec_prepared(conn, 'insert_message', [channel, value]){|r| r.getvalue(0,0).to_i}}
  end

  def clear_global_backlog(backlog_id, num_to_keep)
    if backlog_id > num_to_keep
      hold{|conn| exec_prepared(conn, 'clear_global_backlog', [backlog_id - num_to_keep])}
      nil
    end
  end

  def clear_channel_backlog(channel, backlog_id, num_to_keep)
    hold{|conn| exec_prepared(conn, 'clear_channel_backlog', [channel, backlog_id, num_to_keep])}
    nil
  end

  def expire(max_backlog_age)
    hold{|conn| exec_prepared(conn, 'expire', [max_backlog_age])}
    nil
  end

  def backlog(channel, backlog_id)
    hold{|conn| exec_prepared(conn, 'channel_backlog', [channel, backlog_id]){|r| r.values.each{|a| a[0] = a[0].to_i}}} || []
  end

  def global_backlog(backlog_id)
    hold{|conn| exec_prepared(conn, 'global_backlog', [backlog_id]){|r| r.values.each{|a| a[0] = a[0].to_i}}} || []
  end

  def get_value(channel, id)
    hold{|conn| exec_prepared(conn, 'get_message', [channel, id]){|r| r.getvalue(0,0)}}
  end

  def reconnect
    sync do
      @listening_on.clear
      @available.clear
    end
  end

  # Dangerous, drops the message_bus table containing the backlog if it exists.
  def reset!
    hold do |conn|
      conn.exec 'DROP TABLE IF EXISTS message_bus'
      create_table(conn)
    end
  end

  def max_id(channel=nil)
    block = proc do |r|
      if r.ntuples > 0
        r.getvalue(0,0).to_i
      else
        0
      end
    end

    if channel
      hold{|conn| exec_prepared(conn, 'max_channel_id', [channel], &block)}
    else
      hold{|conn| exec_prepared(conn, 'max_id', &block)}
    end
  end

  def publish(channel, data)
    hold{|conn| exec_prepared(conn, 'publish', [channel, data])}
  end

  def subscribe(channel)
    obj = Object.new
    sync{@listening_on[channel] = obj}
    listener = Listener.new
    yield listener
    
    conn = raw_pg_connection
    conn.exec "LISTEN #{channel}"
    listener.do_sub.call
    while listening_on?(channel, obj)
      conn.wait_for_notify(10) do |_,_,payload|
        break unless listening_on?(channel, obj)
        listener.do_message.call(nil, payload)
      end
    end
    listener.do_unsub.call

    conn.exec "UNLISTEN #{channel}"
    nil
  end

  def unsubscribe
    sync{@listening_on.clear}
  end

  private

  def exec_prepared(conn, *a)
    r = conn.exec_prepared(*a)
    yield r if block_given?
  ensure
    r.clear if r.respond_to?(:clear)
  end

  def create_table(conn)
    conn.exec 'CREATE TABLE message_bus (id bigserial PRIMARY KEY, channel text NOT NULL, value text NOT NULL CHECK (octet_length(value) >= 2), added_at timestamp DEFAULT CURRENT_TIMESTAMP NOT NULL)'
    conn.exec 'CREATE INDEX table_channel_id_index ON message_bus (channel, id)'
    conn.exec 'CREATE INDEX table_added_at_index ON message_bus (added_at)'
    nil
  end

  def hold
    current_pid = Process.pid
    if current_pid != @pid
      @pid = current_pid
      sync do
        INHERITED_CONNECTIONS.concat(@available)
        @available.clear
      end
    end

    if conn = sync{@allocated[Thread.current]}
      return yield(conn)
    end
      
    begin
      conn = sync{@available.shift} || new_pg_connection
      sync{@allocated[Thread.current] = conn}
      yield conn
    rescue PG::ConnectionBad, PG::UnableToSend => e
      # don't add this connection back to the pool
    ensure
      sync{@allocated.delete(Thread.current)}
      if Process.pid != current_pid
        sync{INHERITED_CONNECTIONS << conn}
      elsif conn && !e
        sync{@available << conn}
      end
    end
  end

  def raw_pg_connection
    PG::Connection.connect(@config[:backend_options] || {})
  end

  def new_pg_connection
    conn = raw_pg_connection

    begin
      conn.exec("SELECT 'message_bus'::regclass")
    rescue PG::UndefinedTable
      create_table(conn)
    end

    conn.exec 'PREPARE insert_message AS INSERT INTO message_bus (channel, value) VALUES ($1, $2) RETURNING id'
    conn.exec 'PREPARE clear_global_backlog AS DELETE FROM message_bus WHERE (id <= $1)'
    conn.exec 'PREPARE clear_channel_backlog AS DELETE FROM message_bus WHERE ((channel = $1) AND (id <= (SELECT id FROM message_bus WHERE ((channel = $1) AND (id <= $2)) ORDER BY id DESC LIMIT 1 OFFSET $3)))'
    conn.exec 'PREPARE channel_backlog AS SELECT id, value FROM message_bus WHERE ((channel = $1) AND (id > $2)) ORDER BY id'
    conn.exec 'PREPARE global_backlog AS SELECT id, channel, value FROM message_bus WHERE (id > $1) ORDER BY id'
    conn.exec "PREPARE expire AS DELETE FROM message_bus WHERE added_at < CURRENT_TIMESTAMP - ($1::text || ' seconds')::interval"
    conn.exec 'PREPARE get_message AS SELECT value FROM message_bus WHERE ((channel = $1) AND (id = $2))'
    conn.exec 'PREPARE max_channel_id AS SELECT max(id) FROM message_bus WHERE (channel = $1)'
    conn.exec 'PREPARE max_id AS SELECT max(id) FROM message_bus'
    conn.exec 'PREPARE publish AS SELECT pg_notify($1, $2)'

    conn
  end

  def listening_on?(channel, obj)
    sync{@listening_on[channel]} == obj
  end

  def sync
    @mutex.synchronize{yield}
  end
end

class MessageBus::Postgres::ReliablePubSub
  attr_reader :subscribed
  attr_accessor :max_backlog_size, :max_global_backlog_size, :max_backlog_age, :clear_every

  UNSUB_MESSAGE = "$$UNSUBSCRIBE"

  def self.reset!(config)
    MessageBus::Postgres::Client.new(config).reset!
  end

  # max_backlog_size is per multiplexed channel
  def initialize(config = {}, max_backlog_size = 1000)
    @config = config
    @max_backlog_size = max_backlog_size
    @max_global_backlog_size = 2000
    # after 7 days inactive backlogs will be removed
    @max_backlog_age = 604800
    @clear_every = config[:clear_every] || 1
  end

  def new_connection
    MessageBus::Postgres::Client.new(@config)
  end

  def backend
    :postgres
  end

  def after_fork
    client.reconnect
  end

  def postgresql_channel_name
    db = @config[:db] || 0
    "_message_bus_#{db}"
  end

  def client
    @client ||= new_connection
  end

  # use with extreme care, will nuke all of the data
  def reset!
    client.reset!
  end

  def publish(channel, data, queue_in_memory=true)
    client = self.client
    backlog_id = client.add(channel, data)
    msg = MessageBus::Message.new backlog_id, backlog_id, channel, data
    payload = msg.encode
    client.publish postgresql_channel_name, payload
    if backlog_id % clear_every == 0
      client.clear_global_backlog(backlog_id, @max_global_backlog_size)
      client.expire(@max_backlog_age)
      client.clear_channel_backlog(channel, backlog_id, @max_backlog_size)
    end

    backlog_id
  end

  def last_id(channel)
    client.max_id(channel)
  end

  def backlog(channel, last_id = nil)
    items = client.backlog channel, last_id.to_i

    items.map! do |id, data|
      MessageBus::Message.new id, id, channel, data
    end
  end

  def global_backlog(last_id = nil)
    items = client.global_backlog last_id.to_i

    items.map! do |id, channel, data|
      MessageBus::Message.new id, id, channel, data
    end
  end

  def get_message(channel, message_id)
    if data = client.get_value(channel, message_id)
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
    if highest_id > client.max_id
      highest_id = 0
    end

    global_backlog(highest_id).each do |old|
      yield old
      highest_id = old.global_id
    end

    highest_id
  end

  def global_unsubscribe
    client.publish(postgresql_channel_name, UNSUB_MESSAGE)
    @subscribed = false
  end

  def global_subscribe(last_id=nil, &blk)
    raise ArgumentError unless block_given?
    highest_id = last_id

    begin
      client.subscribe(postgresql_channel_name) do |on|
        h = {}

        on.subscribe do
          if highest_id
            process_global_backlog(highest_id) do |m|
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
            @subscribed = false
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
              h = nil if h.empty?
              yield m
            end
          else
            yield m
          end
        end
      end
    rescue => error
      MessageBus.logger.warn "#{error} subscribe failed, reconnecting in 1 second. Call stack\n#{error.backtrace.join("\n")}"
      sleep 1
      retry
    end
  end

  MessageBus::BACKENDS[:postgres] = self
end
