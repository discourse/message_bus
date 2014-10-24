# require 'thin'
# require 'eventmachine'
# require 'rack'
# require 'redis'

require "message_bus/version"
require "message_bus/message"
require "message_bus/reliable_pub_sub"
require "message_bus/client"
require "message_bus/connection_manager"
require "message_bus/message_handler"
require "message_bus/diagnostics"
require "message_bus/rack/middleware"
require "message_bus/rack/diagnostics"
require "monitor.rb"

# we still need to take care of the logger
if defined?(::Rails)
  require 'message_bus/rails/railtie'
end

module MessageBus; end
class MessageBus::InvalidMessage < Exception; end
class MessageBus::BusDestroyed < Exception; end

module MessageBus::Implementation

  # Like Mutex but safe for recursive calls
  class Synchronizer
    include MonitorMixin
  end

  def initialize
    @mutex = Synchronizer.new
  end

  def cache_assets=(val)
    @cache_assets = val
  end

  def cache_assets
    if defined? @cache_assets
      @cache_assets
    else
      true
    end
  end

  def logger=(logger)
    @logger = logger
  end

  def logger
    return @logger if @logger
    require 'logger'
    @logger = Logger.new(STDOUT)
  end

  def long_polling_enabled?
    @long_polling_enabled == false ? false : true
  end

  def long_polling_enabled=(val)
    @long_polling_enabled = val
  end

  # The number of simultanuous clients we can service
  #  will revert to polling if we are out of slots
  def max_active_clients=(val)
    @max_active_clients = val
  end

  def max_active_clients
    @max_active_clients || 1000
  end

  def rack_hijack_enabled?
    if @rack_hijack_enabled.nil?
      @rack_hijack_enabled = true

      # without this switch passenger will explode
      # it will run out of connections after about 10
      if defined? PhusionPassenger
        @rack_hijack_enabled = false
        if PhusionPassenger.respond_to? :advertised_concurrency_level
          PhusionPassenger.advertised_concurrency_level = 0
          @rack_hijack_enabled = true
        end
      end
    end

    @rack_hijack_enabled
  end

  def rack_hijack_enabled=(val)
    @rack_hijack_enabled = val
  end

  def long_polling_interval=(millisecs)
    @long_polling_interval = millisecs
  end

  def long_polling_interval
    @long_polling_interval || 25 * 1000
  end

  def off
    @off = true
  end

  def on
    @off = false
  end

  # Allow us to inject a redis db
  def redis_config=(config)
    @redis_config = config
  end

  def redis_config
    @redis_config ||= {}
  end

  def site_id_lookup(&blk)
    @site_id_lookup = blk if blk
    @site_id_lookup
  end

  def user_id_lookup(&blk)
    @user_id_lookup = blk if blk
    @user_id_lookup
  end

  def group_ids_lookup(&blk)
    @group_ids_lookup = blk if blk
    @group_ids_lookup
  end

  def is_admin_lookup(&blk)
    @is_admin_lookup = blk if blk
    @is_admin_lookup
  end

  def access_control_allow_origin_lookup(&blk)
    @access_control_allow_origin_lookup = blk if blk
    @access_control_allow_origin_lookup
  end

  def client_filter(channel, &blk)
    @client_filters ||= {}
    @client_filters[channel] = blk if blk
    @client_filters[channel]
  end

  def around_client_batch(channel, &blk)
    @around_client_batches ||= {}
    @around_client_batches[channel] = blk if blk
    @around_client_batches[channel]
  end

  def on_connect(&blk)
    @on_connect = blk if blk
    @on_connect
  end

  def on_disconnect(&blk)
    @on_disconnect = blk if blk
    @on_disconnect
  end

  def allow_broadcast=(val)
    @allow_broadcast = val
  end

  def allow_broadcast?
    @allow_broadcast ||=
      if defined? ::Rails
        ::Rails.env.test? || ::Rails.env.development?
      else
        false
      end
  end

  def reliable_pub_sub
    @mutex.synchronize do
      return nil if @destroyed
      @reliable_pub_sub ||= MessageBus::ReliablePubSub.new redis_config
    end
  end

  def enable_diagnostics
    MessageBus::Diagnostics.enable
  end

  def publish(channel, data, opts = nil)
    return if @off
    @mutex.synchronize do
      raise ::MessageBus::BusDestroyed if @destroyed
    end

    user_ids = nil
    group_ids = nil
    if opts
      user_ids = opts[:user_ids]
      group_ids = opts[:group_ids]
    end

    raise ::MessageBus::InvalidMessage if (user_ids || group_ids) && global?(channel)

    encoded_data = JSON.dump({
      data: data,
      user_ids: user_ids,
      group_ids: group_ids
    })

    reliable_pub_sub.publish(encode_channel_name(channel), encoded_data)
  end

  def blocking_subscribe(channel=nil, &blk)
    if channel
      reliable_pub_sub.subscribe(encode_channel_name(channel), &blk)
    else
      reliable_pub_sub.global_subscribe(&blk)
    end
  end

  ENCODE_SITE_TOKEN = "$|$"

  # encode channel name to include site
  def encode_channel_name(channel)
    if site_id_lookup && !global?(channel)
      raise ArgumentError.new channel if channel.include? ENCODE_SITE_TOKEN
      "#{channel}#{ENCODE_SITE_TOKEN}#{site_id_lookup.call}"
    else
      channel
    end
  end

  def decode_channel_name(channel)
    channel.split(ENCODE_SITE_TOKEN)
  end

  def subscribe(channel=nil, &blk)
    subscribe_impl(channel, nil, &blk)
  end

  def unsubscribe(channel=nil, &blk)
    unsubscribe_impl(channel, nil, &blk)
  end

  def local_unsubscribe(channel=nil, &blk)
    site_id = site_id_lookup.call if site_id_lookup
    unsubscribe_impl(channel, site_id, &blk)
  end

  # subscribe only on current site
  def local_subscribe(channel=nil, &blk)
    site_id = site_id_lookup.call if site_id_lookup && ! global?(channel)
    subscribe_impl(channel, site_id, &blk)
  end

  def backlog(channel=nil, last_id)
    old =
      if channel
        reliable_pub_sub.backlog(encode_channel_name(channel), last_id)
      else
        reliable_pub_sub.global_backlog(last_id)
      end

    old.each{ |m|
      decode_message!(m)
    }
    old
  end

  def last_id(channel)
    reliable_pub_sub.last_id(encode_channel_name(channel))
  end

  def last_message(channel)
    if last_id = last_id(channel)
      messages = backlog(channel, last_id-1)
      if messages
        messages[0]
      end
    end
  end

  def destroy
    @mutex.synchronize do
      @subscriptions ||= {}
      reliable_pub_sub.global_unsubscribe
      @destroyed = true
    end
    @subscriber_thread.join if @subscriber_thread
  end

  def after_fork
    reliable_pub_sub.after_fork
    ensure_subscriber_thread
  end

  def listening?
    @subscriber_thread && @subscriber_thread.alive?
  end

  # will reset all keys
  def reset!
    reliable_pub_sub.reset!
  end

  protected

  def global?(channel)
    channel && channel.start_with?('/global/'.freeze)
  end

  def decode_message!(msg)
    channel, site_id = decode_channel_name(msg.channel)
    msg.channel = channel
    msg.site_id = site_id
    parsed = JSON.parse(msg.data)
    msg.data = parsed["data"]
    msg.user_ids = parsed["user_ids"]
    msg.group_ids = parsed["group_ids"]
  end

  def subscribe_impl(channel, site_id, &blk)

    raise MessageBus::BusDestroyed if @destroyed

    @subscriptions ||= {}
    @subscriptions[site_id] ||= {}
    @subscriptions[site_id][channel] ||=  []
    @subscriptions[site_id][channel] << blk
    ensure_subscriber_thread

    attempts = 100
    while attempts > 0 && !reliable_pub_sub.subscribed
      sleep 0.001
      attempts-=1
    end

    raise MessageBus::BusDestroyed if @destroyed
    blk
  end

  def unsubscribe_impl(channel, site_id, &blk)

    @mutex.synchronize do
      if blk
        @subscriptions[site_id][channel].delete blk
      else
        @subscriptions[site_id][channel] = []
      end
    end

  end


  def ensure_subscriber_thread
    @mutex.synchronize do
      return if (@subscriber_thread && @subscriber_thread.alive?) || @destroyed
      @subscriber_thread = new_subscriber_thread
    end
  end

  def new_subscriber_thread
    Thread.new do
      global_subscribe_thread unless @destroyed
    end
  end

  def global_subscribe_thread
    reliable_pub_sub.global_subscribe do |msg|
      begin
        decode_message!(msg)
        globals, locals, local_globals, global_globals = nil

        @mutex.synchronize do
          raise MessageBus::BusDestroyed if @destroyed
          globals = @subscriptions[nil]
          locals = @subscriptions[msg.site_id] if msg.site_id

          global_globals = globals[nil] if globals
          local_globals = locals[nil] if locals

          globals = globals[msg.channel] if globals
          locals = locals[msg.channel] if locals
        end

        multi_each(globals,locals, global_globals, local_globals) do |c|
          begin
            c.call msg
          rescue => e
            MessageBus.logger.warn "failed to deliver message, skipping #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
          end
        end
      rescue => e
        MessageBus.logger.warn "failed to process message #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
      end
    end
  end

  def multi_each(*args,&block)
    args.each do |a|
      a.each(&block) if a
    end
  end

end

module MessageBus
  extend MessageBus::Implementation
  initialize
end

# allows for multiple buses per app
class MessageBus::Instance
  include MessageBus::Implementation
end
