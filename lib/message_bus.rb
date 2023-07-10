# frozen_string_literal: true

require "monitor"
require "set"

require_relative "message_bus/version"
require_relative "message_bus/message"
require_relative "message_bus/client"
require_relative "message_bus/connection_manager"
require_relative "message_bus/rack/middleware"
require_relative "message_bus/timer_thread"
require_relative "message_bus/codec/base"
require_relative "message_bus/backends"
require_relative "message_bus/backends/base"

# @see MessageBus::Implementation
module MessageBus; end
MessageBus::BACKENDS = {}
class MessageBus::InvalidMessage < StandardError; end
class MessageBus::InvalidMessageTarget < MessageBus::InvalidMessage; end
class MessageBus::BusDestroyed < StandardError; end

# The main server-side interface to a message bus for the purposes of
# configuration, publishing and subscribing
module MessageBus::Implementation
  # @return [Hash<Symbol => Object>] Configuration options hash
  attr_reader :config

  # Like Mutex but safe for recursive calls
  class Synchronizer
    include MonitorMixin
  end

  def initialize
    @config = {}
    @mutex = Synchronizer.new
    @off = false
    @off_disable_publish = false
    @destroyed = false
    @timer_thread = nil
    @subscriber_thread = nil
  end

  # @param [Logger] logger a logger object to be used by the bus
  # @return [void]
  def logger=(logger)
    configure(logger: logger)
  end

  # @return [Logger] the logger used by the bus. If not explicitly set,
  #   is configured to log to STDOUT at INFO level.
  def logger
    return @config[:logger] if @config[:logger]

    require 'logger'
    logger = Logger.new(STDOUT)
    logger.level = Logger::INFO
    configure(logger: logger)
    logger
  end

  # @return [Boolean] whether or not chunked encoding is enabled. If not
  #   explicitly set, defaults to true.
  def chunked_encoding_enabled?
    @config[:chunked_encoding_enabled] == false ? false : true
  end

  # @param [Boolean] val whether or not to enable chunked encoding
  # @return [void]
  def chunked_encoding_enabled=(val)
    configure(chunked_encoding_enabled: val)
  end

  # @return [Boolean] whether or not long polling is enabled. If not explicitly
  #   set, defaults to true.
  def long_polling_enabled?
    @config[:long_polling_enabled] == false ? false : true
  end

  # @param [Boolean] val whether or not to enable long polling
  # @return [void]
  def long_polling_enabled=(val)
    configure(long_polling_enabled: val)
  end

  # @param [Integer] val The number of simultaneous clients we can service;
  #   will revert to polling if we are out of slots
  # @return [void]
  def max_active_clients=(val)
    configure(max_active_clients: val)
  end

  # @return [Integer] The number of simultaneous clients we can service;
  #   will revert to polling if we are out of slots. Defaults to 1000 if not
  #   explicitly set.
  def max_active_clients
    @config[:max_active_clients] || 1000
  end

  # @return [Boolean] whether or not Rack Hijack is enabled. If not explicitly
  #   set, will default to true, unless we're on Passenger without the ability
  #   to set the advertised_concurrency_level to 0.
  def rack_hijack_enabled?
    if @config[:rack_hijack_enabled].nil?
      enable = true

      # without this switch passenger will explode
      # it will run out of connections after about 10
      if defined? PhusionPassenger
        enable = false
        if PhusionPassenger.respond_to? :advertised_concurrency_level
          PhusionPassenger.advertised_concurrency_level = 0
          enable = true
        end
      end
      configure(rack_hijack_enabled: enable)
    end

    @config[:rack_hijack_enabled]
  end

  # @param [Boolean] val whether or not to enable Rack Hijack
  # @return [void]
  def rack_hijack_enabled=(val)
    configure(rack_hijack_enabled: val)
  end

  # @param [Integer] millisecs the long-polling interval in milliseconds
  # @return [void]
  def long_polling_interval=(millisecs)
    configure(long_polling_interval: millisecs)
  end

  # @return [Integer] the long-polling interval in milliseconds. If not
  #   explicitly set, defaults to 25,000.
  def long_polling_interval
    @config[:long_polling_interval] || 25 * 1000
  end

  # @param [String] route Message bus will listen to requests on this route.
  # @return [void]
  def base_route=(route)
    configure(base_route: route.gsub(Regexp.new('\A(?!/)|(?<!/)\Z|//+'), "/"))
  end

  # @return [String] the route that message bus will respond to. If not
  #   explicitly set, defaults to "/". Requests to "#{base_route}message-bus/*" will be handled
  #   by the message bus server.
  def base_route
    @config[:base_route] || "/"
  end

  # @return [Boolean] whether the bus is disabled or not
  def off?
    @off
  end

  # Disables publication to the bus
  # @param [Boolean] disable_publish Whether or not to disable publishing
  # @return [void]
  def off(disable_publish: true)
    @off = true
    @off_disable_publish = disable_publish
  end

  # Enables publication to the bus
  # @return [void]
  def on
    @destroyed = @off = @off_disable_publish = false
  end

  # Overrides existing configuration
  # @param [Hash<Symbol => Object>] config values to merge into existing config
  # @return [void]
  def configure(config)
    @config.merge!(config)
  end

  # Overrides existing configuration, explicitly enabling the redis backend
  # @param [Hash<Symbol => Object>] config values to merge into existing config
  # @return [void]
  def redis_config=(config)
    configure(config.merge(backend: :redis))
  end

  alias redis_config config

  # @yield [env] a routine to determine the site ID for a subscriber
  # @yieldparam [optional, Rack::Request::Env] env the subscriber request environment
  # @yieldreturn [optional, String] the site ID for the subscriber
  # @return [void]
  def site_id_lookup(&blk)
    configure(site_id_lookup: blk) if blk
    @config[:site_id_lookup]
  end

  # @yield [env] a routine to determine the user ID for a subscriber (authenticate)
  # @yieldparam [optional, Rack::Request::Env] env the subscriber request environment
  # @yieldreturn [optional, String, Integer] the user ID for the subscriber
  # @return [void]
  def user_id_lookup(&blk)
    configure(user_id_lookup: blk) if blk
    @config[:user_id_lookup]
  end

  # @yield [env] a routine to determine the group IDs for a subscriber
  # @yieldparam [optional, Rack::Request::Env] env the subscriber request environment
  # @yieldreturn [optional, Array<String,Integer>] the group IDs for the subscriber
  # @return [void]
  def group_ids_lookup(&blk)
    configure(group_ids_lookup: blk) if blk
    @config[:group_ids_lookup]
  end

  # @yield [env] a routine to determine if a request comes from an admin user
  # @yieldparam [Rack::Request::Env] env the subscriber request environment
  # @yieldreturn [Boolean] whether or not the request is from an admin user
  # @return [void]
  def is_admin_lookup(&blk)
    configure(is_admin_lookup: blk) if blk
    @config[:is_admin_lookup]
  end

  # @yield [env, e] a routine to handle exceptions raised when handling a subscriber request
  # @yieldparam [Rack::Request::Env] env the subscriber request environment
  # @yieldparam [Exception] e the exception that was raised
  # @yieldreturn [optional, Array<(Integer,Hash,Array)>] a Rack response to be delivered
  # @return [void]
  def on_middleware_error(&blk)
    configure(on_middleware_error: blk) if blk
    @config[:on_middleware_error]
  end

  # @yield [env] a routine to determine extra headers to be set on a subscriber response
  # @yieldparam [Rack::Request::Env] env the subscriber request environment
  # @yieldreturn [Hash<String => String>] the extra headers to set on the response
  # @return [void]
  def extra_response_headers_lookup(&blk)
    configure(extra_response_headers_lookup: blk) if blk
    @config[:extra_response_headers_lookup]
  end

  def on_connect(&blk)
    configure(on_connect: blk) if blk
    @config[:on_connect]
  end

  def on_disconnect(&blk)
    configure(on_disconnect: blk) if blk
    @config[:on_disconnect]
  end

  # @param [Boolean] val whether or not to allow broadcasting (debugging)
  # @return [void]
  def allow_broadcast=(val)
    configure(allow_broadcast: val)
  end

  # @return [Boolean] whether or not broadcasting is allowed. If not explicitly
  #   set, defaults to false unless we're in Rails test or development mode.
  def allow_broadcast?
    @config[:allow_broadcast] ||=
      if defined? ::Rails.env
        ::Rails.env.test? || ::Rails.env.development?
      else
        false
      end
  end

  # @param [MessageBus::Codec::Base] codec used to encode and decode Message payloads
  # @return [void]
  def transport_codec=(codec)
    configure(transport_codec: codec)
  end

  # @return [MessageBus::Codec::Base] codec used to encode and decode Message payloads
  def transport_codec
    @config[:transport_codec] ||= MessageBus::Codec::Json.new
  end

  # @param [MessageBus::Backend::Base] backend_instance A configured backend
  # @return [void]
  def backend_instance=(backend_instance)
    configure(backend_instance: backend_instance)
  end

  def reliable_pub_sub=(pub_sub)
    logger.warn "MessageBus.reliable_pub_sub= is deprecated, use MessageBus.backend_instance= instead."
    self.backend_instance = pub_sub
  end

  # @return [MessageBus::Backend::Base] the configured backend. If not
  #   explicitly set, will be loaded based on the configuration provided.
  def backend_instance
    @mutex.synchronize do
      return nil if @destroyed

      # Make sure logger is loaded before config is
      # passed to backend.
      logger

      @config[:backend_instance] ||= begin
        @config[:backend_options] ||= {}
        require "message_bus/backends/#{backend}"
        MessageBus::BACKENDS[backend].new @config
      end
    end
  end

  def reliable_pub_sub
    logger.warn "MessageBus.reliable_pub_sub is deprecated, use MessageBus.backend_instance instead."
    backend_instance
  end

  # @return [Symbol] the name of the backend implementation configured
  def backend
    @config[:backend] || :redis
  end

  # Publishes a message to a channel
  #
  # @param [String] channel the name of the channel to which the message should be published
  # @param [JSON] data some data to publish to the channel. Must be an object that can be encoded as JSON
  # @param [Hash] opts
  # @option opts [Array<String>] :client_ids (`nil`) the unique client IDs to which the message should be available. If nil, available to all.
  # @option opts [Array<String,Integer>] :user_ids (`nil`) the user IDs to which the message should be available. If nil, available to all.
  # @option opts [Array<String,Integer>] :group_ids (`nil`) the group IDs to which the message should be available. If nil, available to all.
  # @option opts [String] :site_id (`nil`) the site ID to scope the message to; used for hosting multiple
  #   applications or instances of an application against a single message_bus
  # @option opts [nil,Integer] :max_backlog_age the longest amount of time a message may live in a backlog before being removed, in seconds
  # @option opts [nil,Integer] :max_backlog_size the largest permitted size (number of messages) for the channel backlog; beyond this capacity, old messages will be dropped
  #
  # @return [Integer] the channel-specific ID the message was given
  #
  # @raise [MessageBus::BusDestroyed] if the bus is destroyed
  # @raise [MessageBus::InvalidMessage] if attempting to put permission restrictions on a globally-published message
  # @raise [MessageBus::InvalidMessageTarget] if attempting to publish to a empty group of users
  def publish(channel, data, opts = nil)
    return if @off_disable_publish

    @mutex.synchronize do
      raise ::MessageBus::BusDestroyed if @destroyed
    end

    user_ids = nil
    group_ids = nil
    client_ids = nil

    site_id = nil
    if opts
      user_ids = opts[:user_ids]
      group_ids = opts[:group_ids]
      client_ids = opts[:client_ids]
      site_id = opts[:site_id]
    end

    if (user_ids || group_ids) && global?(channel)
      raise ::MessageBus::InvalidMessage
    end

    if (user_ids == []) || (group_ids == []) || (client_ids == [])
      raise ::MessageBus::InvalidMessageTarget
    end

    encoded_data = transport_codec.encode({
      "data" => data,
      "user_ids" => user_ids,
      "group_ids" => group_ids,
      "client_ids" => client_ids
    })

    channel_opts = {}

    if opts
      if ((age = opts[:max_backlog_age]) || (size = opts[:max_backlog_size]))
        channel_opts[:max_backlog_size] = size
        channel_opts[:max_backlog_age] = age
      end

      if opts.has_key?(:queue_in_memory)
        channel_opts[:queue_in_memory] = opts[:queue_in_memory]
      end
    end

    encoded_channel_name = encode_channel_name(channel, site_id)
    backend_instance.publish(encoded_channel_name, encoded_data, channel_opts)
  end

  # Subscribe to messages. Each message will be delivered by yielding to the
  # passed block as soon as it is available. This will block until subscription
  # is terminated.
  #
  # @param [String,nil] channel the name of the channel to which we should
  #   subscribe. If `nil`, messages on every channel will be provided.
  #
  # @yield [message] a message-handler block
  # @yieldparam [MessageBus::Message] message each message as it is delivered
  #
  # @return [void]
  def blocking_subscribe(channel = nil, &blk)
    if channel
      backend_instance.subscribe(encode_channel_name(channel), &blk)
    else
      backend_instance.global_subscribe(&blk)
    end
  end

  # Subscribe to messages on a particular channel. Each message since the
  # last ID specified will be delivered by yielding to the passed block as
  # soon as it is available. This will not block, but instead the callbacks
  # will be executed asynchronously in a dedicated subscriber thread.
  #
  # @param [String] channel the name of the channel to which we should subscribe
  # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
  #
  # @yield [message] a message-handler block
  # @yieldparam [MessageBus::Message] message each message as it is delivered
  #
  # @return [Proc] the callback block that will be executed
  def subscribe(channel = nil, last_id = -1, &blk)
    subscribe_impl(channel, nil, last_id, &blk)
  end

  # Subscribe to messages on a particular channel, filtered by the current site
  # (@see #site_id_lookup). Each message since the last ID specified will be
  # delivered by yielding to the passed block as soon as it is available. This
  # will not block, but instead the callbacks will be executed asynchronously
  # in a dedicated subscriber thread.
  #
  # @param [String] channel the name of the channel to which we should subscribe
  # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
  #
  # @yield [message] a message-handler block
  # @yieldparam [MessageBus::Message] message each message as it is delivered
  #
  # @return [Proc] the callback block that will be executed
  def local_subscribe(channel = nil, last_id = -1, &blk)
    site_id = site_id_lookup.call if site_id_lookup && !global?(channel)
    subscribe_impl(channel, site_id, last_id, &blk)
  end

  # Removes a subscription to a particular channel.
  #
  # @param [String] channel the name of the channel from which we should unsubscribe
  # @param [Proc,nil] blk the callback which should be removed. If `nil`, removes all.
  #
  # @return [void]
  def unsubscribe(channel = nil, &blk)
    unsubscribe_impl(channel, nil, &blk)
  end

  # Removes a subscription to a particular channel, filtered by the current site
  # (@see #site_id_lookup).
  #
  # @param [String] channel the name of the channel from which we should unsubscribe
  # @param [Proc,nil] blk the callback which should be removed. If `nil`, removes all.
  #
  # @return [void]
  def local_unsubscribe(channel = nil, &blk)
    site_id = site_id_lookup.call if site_id_lookup
    unsubscribe_impl(channel, site_id, &blk)
  end

  # Get messages from the global backlog since the last ID specified
  #
  # @param [#to_i] last_id the global ID of the last message that the caller received
  #
  # @return [Array<MessageBus::Message>] all messages published on any channel since the specified last ID
  def global_backlog(last_id = nil)
    backlog(nil, last_id)
  end

  # Get messages from a channel backlog since the last ID specified, filtered by site
  #
  # @param [String] channel the name of the channel in question
  # @param [#to_i] last_id the channel-specific ID of the last message that the caller received on the specified channel
  # @param [String] site_id the ID of the site by which to filter
  #
  # @return [Array<MessageBus::Message>] all messages published to the specified channel since the specified last ID
  def backlog(channel = nil, last_id = nil, site_id = nil)
    old =
      if channel
        backend_instance.backlog(encode_channel_name(channel, site_id), last_id)
      else
        backend_instance.global_backlog(last_id)
      end

    old.each do |m|
      decode_message!(m)
    end
    old
  end

  # Get the ID of the last message published on a channel, filtered by site
  #
  # @param [String] channel the name of the channel in question
  # @param [String] site_id the ID of the site by which to filter
  #
  # @return [Integer] the channel-specific ID of the last message published to the given channel
  def last_id(channel, site_id = nil)
    backend_instance.last_id(encode_channel_name(channel, site_id))
  end

  # Get the ID of the last message published on multiple channels
  #
  # @param [Array<String>] channels - array of channels to fetch
  # @param [String] site_id - the ID of the site by which to filter
  #
  # @return [Hash] the channel-specific IDs of the last message published to each requested channel
  def last_ids(*channels, site_id: nil)
    encoded_channel_names = channels.map { |c| encode_channel_name(c, site_id) }
    ids = backend_instance.last_ids(*encoded_channel_names)
    channels.zip(ids).to_h
  end

  # Get the last message published on a channel
  #
  # @param [String] channel the name of the channel in question
  #
  # @return [MessageBus::Message] the last message published to the given channel
  def last_message(channel)
    if last_id = last_id(channel)
      messages = backlog(channel, last_id - 1)
      if messages
        messages[0]
      end
    end
  end

  # Stops listening for publications and stops executing scheduled tasks.
  # Mostly used in tests to destroy entire bus.
  # @return [void]
  def destroy
    return if @destroyed

    backend_instance.global_unsubscribe
    backend_instance.destroy

    @mutex.synchronize do
      return if @destroyed

      @subscriptions ||= {}
      @destroyed = true
    end
    @subscriber_thread.join if @subscriber_thread
    timer.stop
  end

  # Performs routines that are necessary after a process fork, typically
  #   triggered by a forking webserver. Performs whatever the backend requires
  #   and ensures the server is listening for publications and running
  #   scheduled tasks.
  # @return [void]
  def after_fork
    backend_instance.after_fork
    ensure_subscriber_thread
    # will ensure timer is running
    timer.queue {}
  end

  # @return [Boolean] whether or not the server is actively listening for
  #   publications on the bus
  def listening?
    @subscriber_thread&.alive?
  end

  # (see MessageBus::Backend::Base#reset!)
  def reset!
    backend_instance.reset! if backend_instance
  end

  # @return [MessageBus::TimerThread] the timer thread used for triggering
  #   scheduled routines at specific times/intervals.
  def timer
    return @timer_thread if @timer_thread

    @timer_thread ||= begin
      t = MessageBus::TimerThread.new
      t.on_error do |e|
        logger.warn "Failed to process job: #{e} #{e.backtrace}"
      end
      t
    end
  end

  # @param [Integer] interval the keepalive interval in seconds.
  #   Set to 0 to disable; anything higher and a keepalive will run every N
  #   seconds. If it fails, the process is killed.
  def keepalive_interval=(interval)
    configure(keepalive_interval: interval)
  end

  # @return [Integer] the keepalive interval in seconds. If not explicitly set,
  #   defaults to `60`.
  def keepalive_interval
    @config[:keepalive_interval] || 60
  end

  # Registers a client message filter that allows messages to be filtered from the client.
  #
  # @param [String,Regexp] channel_prefix channel prefix to match against a message's channel
  #
  # @yield [params, message] query params and a message of the channel that matched the prefix provided
  # @yieldreturn [Boolean] whether the message should be published to the client
  # @return [void]
  def register_client_message_filter(channel_prefix, &blk)
    if blk
      configure(client_message_filters: []) if !@config[:client_message_filters]
      @config[:client_message_filters] << [channel_prefix, blk]
    end
  end

  # @return [Array] returns a hash of message filters that have been registered
  def client_message_filters
    configure(client_message_filters: []) if !@config[:client_message_filters]
    @config[:client_message_filters]
  end

  private

  ENCODE_SITE_TOKEN = "$|$"

  # encode channel name to include site
  def encode_channel_name(channel, site_id = nil)
    if (site_id || site_id_lookup) && !global?(channel)
      raise ArgumentError.new channel if channel.include? ENCODE_SITE_TOKEN

      "#{channel}#{ENCODE_SITE_TOKEN}#{site_id || site_id_lookup.call}"
    else
      channel
    end
  end

  def decode_channel_name(channel)
    channel.split(ENCODE_SITE_TOKEN)
  end

  def global?(channel)
    channel && channel.start_with?('/global/'.freeze)
  end

  def decode_message!(msg)
    channel, site_id = decode_channel_name(msg.channel)
    msg.channel = channel
    msg.site_id = site_id
    parsed = transport_codec.decode(msg.data)
    msg.data = parsed["data"]
    msg.user_ids = parsed["user_ids"]
    msg.group_ids = parsed["group_ids"]
    msg.client_ids = parsed["client_ids"]
  end

  def replay_backlog(channel, last_id, site_id)
    id = nil

    backlog(channel, last_id, site_id).each do |m|
      yield m
      id = m.message_id
    end

    id
  end

  def subscribe_impl(channel, site_id, last_id, &blk)
    return if @off

    raise MessageBus::BusDestroyed if @destroyed

    if last_id >= 0
      # this gets a bit tricky, but we got to ensure ordering so we wrap the block
      original_blk = blk
      current_id = replay_backlog(channel, last_id, site_id, &blk)
      just_yield = false

      # we double check to ensure no messages snuck through while we were subscribing
      blk = proc do |m|
        if just_yield
          original_blk.call m
        else
          if current_id && current_id == (m.message_id - 1)
            original_blk.call m
            just_yield = true
          else
            current_id = replay_backlog(channel, current_id, site_id, &original_blk)
            if (current_id == m.message_id)
              just_yield = true
            end
          end
        end
      end
    end

    @subscriptions ||= {}
    @subscriptions[site_id] ||= {}
    @subscriptions[site_id][channel] ||= []
    @subscriptions[site_id][channel] << blk
    ensure_subscriber_thread

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
      return if @destroyed
      next if @subscriber_thread&.alive?

      @subscriber_thread = new_subscriber_thread
    end

    attempts = 100
    while attempts > 0 && !backend_instance.subscribed
      sleep 0.001
      attempts -= 1
    end
  end

  MIN_KEEPALIVE = 20

  def new_subscriber_thread
    thread = Thread.new do
      begin
        global_subscribe_thread unless @destroyed
      rescue => e
        logger.warn "Unexpected error in subscriber thread #{e}"
      end
    end

    # adjust for possible race condition
    @last_message = Time.now

    blk = proc do
      if !@destroyed && thread.alive? && keepalive_interval > MIN_KEEPALIVE

        publish("/__mb_keepalive__/", Process.pid, user_ids: [-1])
        if (Time.now - (@last_message || Time.now)) > keepalive_interval * 3
          logger.warn "Global messages on #{Process.pid} timed out, message bus is no longer functioning correctly"
        end

        timer.queue(keepalive_interval, &blk) if keepalive_interval > MIN_KEEPALIVE
      end
    end

    timer.queue(keepalive_interval, &blk) if keepalive_interval > MIN_KEEPALIVE

    thread
  end

  def global_subscribe_thread
    # pretend we just got a message
    @last_message = Time.now
    backend_instance.global_subscribe do |msg|
      begin
        @last_message = Time.now
        decode_message!(msg)
        globals, locals, local_globals, global_globals = nil

        @mutex.synchronize do
          return if @destroyed
          next unless @subscriptions

          globals = @subscriptions[nil]
          locals = @subscriptions[msg.site_id] if msg.site_id

          global_globals = globals[nil] if globals
          local_globals = locals[nil] if locals

          globals = globals[msg.channel] if globals
          locals = locals[msg.channel] if locals
        end

        multi_each(globals, locals, global_globals, local_globals) do |c|
          begin
            c.call msg
          rescue => e
            logger.warn "failed to deliver message, skipping #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
          end
        end
      rescue => e
        logger.warn "failed to process message #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
      end
      @global_id = msg.global_id
    end
  end

  def multi_each(*args, &block)
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
# @see MessageBus::Implementation
class MessageBus::Instance
  include MessageBus::Implementation
end

# we still need to take care of the logger
if defined?(::Rails::Engine)
  require_relative 'message_bus/rails/railtie'
end
