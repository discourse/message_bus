module MessageBus::Memory; end

class MessageBus::Memory::Client
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
    @mutex = Mutex.new
    @listeners = []
    reset!
  end

  def add(channel, value)
    listeners = nil
    id = nil
    sync do
      id = @global_id += 1
      chan(channel) << [id, value]
      listeners = @listeners.dup
    end
    msg = MessageBus::Message.new id, id, channel, value
    payload = msg.encode
    listeners.each{|l| l.push(payload)}
    id
  end

  def clear_global_backlog(backlog_id, num_to_keep)
    if backlog_id > num_to_keep
      oldest = backlog_id - num_to_keep
      sync do
        @channels.each_value do |entries|
          entries.delete_if{|id, _| id <= oldest}
        end
      end
      nil
    end
  end

  def clear_channel_backlog(channel, backlog_id, num_to_keep)
    oldest = backlog_id - num_to_keep
    sync{chan(channel).delete_if{|id, _| id <= oldest}}
    nil
  end

  def backlog(channel, backlog_id)
    sync{chan(channel).select{|id, _| id > backlog_id}}
  end

  def global_backlog(backlog_id)
    sync do
      @channels.dup.flat_map do |channel, messages|
        messages.select{|id, _| id > backlog_id}.map{|id, value| [id, channel, value]}
      end.sort
    end
  end

  def get_value(channel, id)
    sync{chan(channel).find{|i, _| i == id}.last}
  end

  # Dangerous, drops the message_bus table containing the backlog if it exists.
  def reset!
    sync do
      @global_id = 0
      @channels = {}
    end
  end

  def max_id(channel=nil)
    if channel
      sync do
        if entry = chan(channel).last
          entry.first
        end
      end
    else
      sync{@global_id - 1}
    end || 0
  end

  def subscribe
    listener = Listener.new
    yield listener

    q = Queue.new
    sync do
      @listeners << q
    end

    listener.do_sub.call
    while msg = q.pop
      listener.do_message.call(nil, msg)
    end
    listener.do_unsub.call
    sync do
      @listeners.delete(q)
    end

    nil
  end

  def unsubscribe
    sync{@listeners.each{|l| l.push(nil)}}
  end

  private

  def chan(channel)
    @channels[channel] ||= []
  end

  def sync
    @mutex.synchronize{yield}
  end
end

class MessageBus::Memory::ReliablePubSub
  attr_reader :subscribed
  attr_accessor :max_backlog_size, :max_global_backlog_size, :clear_every

  UNSUB_MESSAGE = "$$UNSUBSCRIBE"

  # max_backlog_size is per multiplexed channel
  def initialize(config = {}, max_backlog_size = 1000)
    @config = config
    @max_backlog_size = max_backlog_size
    @max_global_backlog_size = 2000
    # after 7 days inactive backlogs will be removed
    @clear_every = config[:clear_every] || 1
  end

  def new_connection
    MessageBus::Memory::Client.new(@config)
  end

  def backend
    :memory
  end

  def after_fork
    nil
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
    if backlog_id % clear_every == 0
      client.clear_global_backlog(backlog_id, @max_global_backlog_size)
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
    last_id = last_id.to_i

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
    client.unsubscribe
    @subscribed = false
  end

  def global_subscribe(last_id=nil, &blk)
    raise ArgumentError unless block_given?
    highest_id = last_id

    begin
      client.subscribe do |on|
        h = {}

        on.subscribe do
          if highest_id
            process_global_backlog(highest_id) do |m|
              h[m.global_id] = true
              yield m
            end
          end
          @subscribed = true
        end

        on.unsubscribe do
          @subscribed = false
        end

        on.message do |c,m|
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

  MessageBus::BACKENDS[:memory] = self
end
