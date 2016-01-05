require 'json' unless defined? ::JSON

class MessageBus::ConnectionManager
  require 'monitor'
  include MonitorMixin

  def initialize(bus=nil)
    @clients = {}
    @subscriptions = {}
    @bus = bus || MessageBus
    mon_initialize
  end

  def notify_clients(msg)
    synchronize do
      begin
        site_subs = @subscriptions[msg.site_id]
        subscription = site_subs[msg.channel] if site_subs

        return unless subscription

        subscription.each do |client_id|
          client = @clients[client_id]
          if client && client.allowed?(msg)
            begin
              client.synchronize do
                client << msg
              end
            rescue
              # pipe may be broken, move on
            end
            # turns out you can delete from a set while itereating
            remove_client(client) if client.closed?
          end
        end

      rescue => e
        MessageBus.logger.error "notify clients crash #{e} : #{e.backtrace}"
      end
    end
  end

  def add_client(client)
    synchronize do
      existing = @clients[client.client_id]
      if existing && existing.seq > client.seq
        client.cancel
      else
        if existing
          remove_client(existing)
          existing.cancel
        end

        @clients[client.client_id] = client
        @subscriptions[client.site_id] ||= {}
        client.subscriptions.each do |k,v|
          subscribe_client(client, k)
        end
      end
    end
  end

  def remove_client(c)
    synchronize do
      @clients.delete c.client_id
      @subscriptions[c.site_id].each do |k, set|
        set.delete c.client_id
      end
      if c.cleanup_timer
        # concurrency may cause this to fail
        c.cleanup_timer.cancel rescue nil
      end
    end
  end

  def lookup_client(client_id)
    synchronize do
      @clients[client_id]
    end
  end

  def subscribe_client(client,channel)
    synchronize do
      set = @subscriptions[client.site_id][channel]
      unless set
        set = Set.new
        @subscriptions[client.site_id][channel] = set
      end
      set << client.client_id
    end
  end

  def client_count
    synchronize do
      @clients.length
    end
  end

  def stats
    synchronize do
      {
        client_count: @clients.length,
        subscriptions: @subscriptions
      }
    end
  end

end
