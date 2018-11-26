# frozen_string_literal: true

require 'pg'

require "message_bus/backends/base"

module MessageBus
  module Backends
    # The Postgres backend stores published messages in a single Postgres table
    # with only global IDs, and an index on channel name and ID for fast
    # per-channel lookup. All queries are implemented as prepared statements
    # to reduce the wire-chatter during use. In addition to storage in the
    # table, messages are published using `pg_notify`; this is used for
    # actively subscribed message_bus servers to consume published messages in
    # real-time while connected and forward them to subscribers, while catch-up
    # is performed from the backlog table.
    #
    # @note This backend diverges from the standard in Base in the following ways:
    #
    #   * Does not support in-memory buffering of messages on publication
    #   * Does not expire backlogs until they are published to
    #
    # @see Base general information about message_bus backends
    class Postgres < Base
      class Client
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
          hold { |conn| exec_prepared(conn, 'insert_message', [channel, value]) { |r| r.getvalue(0, 0).to_i } }
        end

        def clear_global_backlog(backlog_id, num_to_keep)
          if backlog_id > num_to_keep
            hold { |conn| exec_prepared(conn, 'clear_global_backlog', [backlog_id - num_to_keep]) }
            nil
          end
        end

        def clear_channel_backlog(channel, backlog_id, num_to_keep)
          hold { |conn| exec_prepared(conn, 'clear_channel_backlog', [channel, backlog_id, num_to_keep]) }
          nil
        end

        def expire(max_backlog_age)
          hold { |conn| exec_prepared(conn, 'expire', [max_backlog_age]) }
          nil
        end

        def backlog(channel, backlog_id)
          hold do |conn|
            exec_prepared(conn, 'channel_backlog', [channel, backlog_id]) { |r| r.values.each { |a| a[0] = a[0].to_i } }
          end || []
        end

        def global_backlog(backlog_id)
          hold do |conn|
            exec_prepared(conn, 'global_backlog', [backlog_id]) { |r| r.values.each { |a| a[0] = a[0].to_i } }
          end || []
        end

        def get_value(channel, id)
          hold { |conn| exec_prepared(conn, 'get_message', [channel, id]) { |r| r.getvalue(0, 0) } }
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

        # use with extreme care, will nuke all of the data
        def expire_all_backlogs!
          reset!
        end

        def max_id(channel = nil)
          block = proc do |r|
            if r.ntuples > 0
              r.getvalue(0, 0).to_i
            else
              0
            end
          end

          if channel
            hold { |conn| exec_prepared(conn, 'max_channel_id', [channel], &block) }
          else
            hold { |conn| exec_prepared(conn, 'max_id', &block) }
          end
        end

        def publish(channel, data)
          hold { |conn| exec_prepared(conn, 'publish', [channel, data]) }
        end

        def subscribe(channel)
          obj = Object.new
          sync { @listening_on[channel] = obj }
          listener = Listener.new
          yield listener

          conn = raw_pg_connection
          conn.exec "LISTEN #{channel}"
          listener.do_sub.call
          while listening_on?(channel, obj)
            conn.wait_for_notify(10) do |_, _, payload|
              break unless listening_on?(channel, obj)

              listener.do_message.call(nil, payload)
            end
          end
          listener.do_unsub.call

          conn.exec "UNLISTEN #{channel}"
          nil
        end

        def unsubscribe
          sync { @listening_on.clear }
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

          if conn = sync { @allocated[Thread.current] }
            return yield(conn)
          end

          begin
            conn = sync { @available.shift } || new_pg_connection
            sync { @allocated[Thread.current] = conn }
            yield conn
          rescue PG::ConnectionBad, PG::UnableToSend => e
            # don't add this connection back to the pool
          ensure
            sync { @allocated.delete(Thread.current) }
            if Process.pid != current_pid
              sync { INHERITED_CONNECTIONS << conn }
            elsif conn && !e
              sync { @available << conn }
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
          sync { @listening_on[channel] } == obj
        end

        def sync
          @mutex.synchronize { yield }
        end
      end

      def self.reset!(config)
        MessageBus::Postgres::Client.new(config).reset!
      end

      # @param [Hash] config
      # @option config [Logger] :logger a logger to which logs will be output
      # @option config [Integer] :clear_every the interval of publications between which the backlog will not be cleared
      # @option config [Hash] :backend_options see PG::Connection.connect for details of which options may be provided
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(config = {}, max_backlog_size = 1000)
        @config = config
        @max_backlog_size = max_backlog_size
        @max_global_backlog_size = 2000
        # after 7 days inactive backlogs will be removed
        @max_backlog_age = 604800
        @clear_every = config[:clear_every] || 1
      end

      # Reconnects to Postgres; used after a process fork, typically triggerd by a forking webserver
      # @see Base#after_fork
      def after_fork
        client.reconnect
      end

      # (see Base#reset!)
      def reset!
        client.reset!
      end

      # (see Base#expire_all_backlogs!)
      def expire_all_backlogs!
        client.expire_all_backlogs!
      end

      # (see Base#publish)
      # @todo :queue_in_memory NOT SUPPORTED
      def publish(channel, data, opts = nil)
        # TODO in memory queue?

        c = client
        backlog_id = c.add(channel, data)
        msg = MessageBus::Message.new backlog_id, backlog_id, channel, data
        payload = msg.encode
        c.publish postgresql_channel_name, payload
        if backlog_id % clear_every == 0
          max_backlog_size = (opts && opts[:max_backlog_size]) || self.max_backlog_size
          max_backlog_age = (opts && opts[:max_backlog_age]) || self.max_backlog_age
          c.clear_global_backlog(backlog_id, @max_global_backlog_size)
          c.expire(max_backlog_age)
          c.clear_channel_backlog(channel, backlog_id, max_backlog_size)
        end

        backlog_id
      end

      # (see Base#last_id)
      def last_id(channel)
        client.max_id(channel)
      end

      # (see Base#last_id)
      def backlog(channel, last_id = 0)
        items = client.backlog channel, last_id.to_i

        items.map! do |id, data|
          MessageBus::Message.new id, id, channel, data
        end
      end

      # (see Base#global_backlog)
      def global_backlog(last_id = 0)
        items = client.global_backlog last_id.to_i

        items.map! do |id, channel, data|
          MessageBus::Message.new id, id, channel, data
        end
      end

      # (see Base#get_message)
      def get_message(channel, message_id)
        if data = client.get_value(channel, message_id)
          MessageBus::Message.new message_id, message_id, channel, data
        else
          nil
        end
      end

      # (see Base#subscribe)
      def subscribe(channel, last_id = nil)
        # trivial implementation for now,
        #   can cut down on connections if we only have one global subscriber
        raise ArgumentError unless block_given?

        global_subscribe(last_id) do |m|
          yield m if m.channel == channel
        end
      end

      # (see Base#global_unsubscribe)
      def global_unsubscribe
        client.publish(postgresql_channel_name, UNSUB_MESSAGE)
        @subscribed = false
      end

      # (see Base#global_subscribe)
      def global_subscribe(last_id = nil)
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

            on.message do |_c, m|
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
          @config[:logger].warn "#{error} subscribe failed, reconnecting in 1 second. Call stack\n#{error.backtrace.join("\n")}"
          sleep 1
          retry
        end
      end

      private

      def client
        @client ||= new_connection
      end

      def new_connection
        Client.new(@config)
      end

      def postgresql_channel_name
        db = @config[:db] || 0
        "_message_bus_#{db}"
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

      MessageBus::BACKENDS[:postgres] = self
    end
  end
end
