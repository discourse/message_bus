# frozen_string_literal: true

require 'json' unless defined? ::JSON

# Manages a set of subscribers with active connections to the server, such that
# messages which are published during the connection may be dispatched.
class MessageBus::ConnectionManager
  require 'monitor'
  include MonitorMixin

  # @param [MessageBus::Instance] bus the message bus for which to manage connections
  def initialize(bus = nil)
    @clients = {}
    @subscriptions = {}
    @bus = bus || MessageBus
    mon_initialize
  end

  # Dispatches a message to any connected clients which are permitted to receive it
  # @param [MessageBus::Message] msg the message to dispatch
  # @return [void]
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
        @bus.logger.error "notify clients crash #{e} : #{e.backtrace}"
      end
    end
  end

  # Keeps track of a client with an active connection
  # @param [MessageBus::Client] client the client to track
  # @return [void]
  def add_client(client)
    synchronize do
      existing = @clients[client.client_id]
      if existing && existing.seq > client.seq
        client.close
      else
        if existing
          remove_client(existing)
          existing.close
        end

        @clients[client.client_id] = client
        @subscriptions[client.site_id] ||= {}
        client.subscriptions.each do |k, _v|
          subscribe_client(client, k)
        end
      end
    end
  end

  # Removes a client
  # @param [MessageBus::Client] c the client to remove
  # @return [void]
  def remove_client(c)
    synchronize do
      @clients.delete c.client_id
      @subscriptions[c.site_id].each do |_k, set|
        set.delete c.client_id
      end
      if c.cleanup_timer
        # concurrency may cause this to fail
        c.cleanup_timer.cancel rescue nil
      end
    end
  end

  # Finds a client by ID
  # @param [String] client_id the client ID to search by
  # @return [MessageBus::Client] the client with the specified ID
  def lookup_client(client_id)
    synchronize do
      @clients[client_id]
    end
  end

  # @return [Integer] the number of tracked clients
  def client_count
    synchronize do
      @clients.length
    end
  end

  private

  def subscribe_client(client, channel)
    synchronize do
      set = @subscriptions[client.site_id][channel]
      unless set
        set = Set.new
        @subscriptions[client.site_id][channel] = set
      end
      set << client.client_id
    end
  end
end
