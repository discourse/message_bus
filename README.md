# MessageBus

A reliable, robust messaging bus for Ruby processes and web clients.

MessageBus implements a Server to Server channel based protocol and Server to Web Client protocol (using polling, long-polling or long-polling + streaming)

Since long-polling is implemented using Rack Hijack and Thin::Async, all common Ruby web servers (Thin, Puma, Unicorn, Passenger) can run MessageBus and handle a large number of concurrent connections that wait on messages.

MessageBus is implemented as Rack middleware and can be used by any Rails / Sinatra or pure Rack application.

## Try it out!

Live chat demo per [examples/chat](https://github.com/SamSaffron/message_bus/tree/master/examples/chat) is at:

### http://chat.samsaffron.com

## Ruby version support

MessageBus only support officially supported versions of Ruby; as of [2018-06-20](https://www.ruby-lang.org/en/news/2018/06/20/support-of-ruby-2-2-has-ended/) this means we only support Ruby version 2.3 and up.

## Can you handle concurrent requests?

**Yes**, MessageBus uses Rack Hijack and this interface allows us to take control of the underlying socket. MessageBus can handle thousands of concurrent long polls on all popular Ruby webservers. MessageBus runs as middleware in your Rack (or by extension Rails) application and does not require a dedicated server. Background work is minimized to ensure it does not interfere with existing non-MessageBus traffic.

## Is this used in production at scale?

**Yes**, MessageBus was extracted out of [Discourse](http://www.discourse.org/) and is used in thousands of production Discourse sites at scale.

## Installation

Add this line to your application's Gemfile:

    gem 'message_bus'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install message_bus

## Usage

Server to Server messaging

```ruby
message_id = MessageBus.publish "/channel", "message"

# in another process / spot

MessageBus.subscribe "/channel" do |msg|
  # block called in a background thread when message is received
end

# subscribe to channel and receive the entire backlog
MessageBus.subscribe "/channel", 0 do |msg|
  # block called in a background thread when message is received
end

# subscribe to channel and receive the backlog starting at message 6
MessageBus.subscribe "/channel", 5 do |msg|
  # block called in a background thread when message is received
end
```

```ruby
# get the ID of the last message on a channel
id = MessageBus.last_id("/channel")

# returns all messages after some id
MessageBus.backlog "/channel", id
```

```ruby
# messages can be targetted at particular users or groups
MessageBus.publish "/channel", "hello", user_ids: [1,2,3], group_ids: [4,5,6]

# messages can be targetted at particular clients (using MessageBus.clientId)
MessageBus.publish "/channel", "hello", client_ids: ["XXX","YYY"]

# message bus determines the user ids and groups based on env

MessageBus.configure(user_id_lookup: proc do |env|
  # this lookup occurs on JS-client poolings, so that server can retrieve backlog
  # for the client considering/matching/filtering user_ids set on published messages
  # if user_id is not set on publish time, any user_id returned here will receive the message

  # return the user id here
end)

MessageBus.configure(group_ids_lookup: proc do |env|
  # return the group ids the user belongs to
  # can be nil or []
end)

# example of message bus to set user_ids from an initializer in Rails and Devise:
# config/inializers/message_bus.rb
MessageBus.user_id_lookup do |env|
  req = Rack::Request.new(env)
  if req.session && req.session["warden.user.user.key"] && req.session["warden.user.user.key"][0][0]
    user = User.find(req.session["warden.user.user.key"][0][0])
    user.id
  end
end
```

```ruby
MessageBus.configure(on_middleware_error: proc do |env, e|
   # If you wish to add special handling based on error
   # return a rack result array: [status, headers, body]
   # If you just want to pass it on return nil
end)
```

#### Disabling message_bus

In certain cases, it is undesirable for message_bus to start up on application start, for example in a Rails application during the `db:create` rake task when using the Postgres backend (which will error trying to connect to the non-existent database to subscribe). You can invoke `MessageBus.off` before the middleware chain is loaded in order to prevent subscriptions and publications from happening; in a Rails app you might do this in an initializer based on some environment variable or some other conditional means.

### Debugging

When setting up MessageBus, it's useful to manually inspect channels before integrating a client application.

You can `curl` MessageBus; this is helpful when trying to debug what may be going wrong. This example uses https://chat.samsaffron.com:

```
curl -H "Content-Type: application/x-www-form-urlencoded" -X POST --data "/message=0" https://chat.samsaffron.com/message-bus/client-id/poll\?dlp\=t
```

You should see a reply with the messages of that channel you requested (in this case `/message`) starting at the message ID you requested (`0`). The URL parameter `dlp=t` disables long-polling: we do not want this request to stay open.

### Diagnostics

MessageBus comes with a diagnostics interface, which you can access at `/message-bus/_diagnostics`. This interface allows you visibility into the runtime behaviour of message_bus.

In order to use the diagnostics UI in your application, it is necessary to:

* Enable it
* Define a user ID for requests
* Define a check for admin role

as an example, you can do something like this:

```ruby
MessageBus.enable_diagnostics # Must be called after `MessageBus.after_fork` if using a forking webserver

MessageBus.user_id_lookup do |_env|
  1
end

MessageBus.is_admin_lookup do |_env|
  true
end
```

Of course, in your real-world application, you would define these values according to your authentication/authorization logic.

### Transport

MessageBus ships with 3 transport mechanisms.

1. Long Polling with chunked encoding (streaming)
2. Long Polling
3. Polling

Long Polling with chunked encoding allows a single connection to stream multiple messages to a client, and this requires HTTP/1.1.

Chunked encoding provides all the benefits of [EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource) with greater browser support (as it works on IE10 and up as well)

To setup NGINX to proxy to your app correctly be sure to enable HTTP1.1 and disable buffering:

```
location /message-bus/ {
  ...
  proxy_http_version 1.1;
  proxy_buffering off;
  ...
}
```

**NOTE**: do not set proxy_buffering off globally, it may have unintended consequences.

In order to disable chunked encoding for a specific client in Javascript:

```javascript
MessageBus.enableChunkedEncoding = false;
```

or as a server-side policy in Ruby for all clients:

```ruby
MessageBus.configure(chunked_encoding_enabled: false)
```

Long Polling requires no special setup; as soon as new data arrives on the channel the server delivers the data and closes the connection.

Polling also requires no special setup; MessageBus will fallback to polling after a tab becomes inactive and remains inactive for a period.

### Multisite support

MessageBus can be used in an environment that hosts multiple sites by multiplexing channels. To use this mode:

```ruby
# define a site_id lookup method, which is executed
# when `MessageBus.publish` is called
MessageBus.configure(site_id_lookup: proc do
  some_method_that_returns_site_id_string
end)

# you may post messages just to this site
MessageBus.publish "/channel", "some message"

# you can also choose to pass the `:site_id`.
# This takes precendence over whatever `site_id_lookup`
# returns
MessageBus.publish "/channel", "some message", site_id: "site-id"

# you may publish messages to ALL sites using the /global/ prefix
MessageBus.publish "/global/channel", "will go to all sites"
```

### Client support

#### JavaScript Client

MessageBus ships a simple ~300 line JavaScript library which provides an API to interact with the server.

JavaScript clients can listen on any channel and receive messages via polling or long polling. You may simply include the source file (located in `assets/` within the message_bus source code):

```html
<script src="message-bus.js" type="text/javascript"></script>
```

or when used in a Rails application, import it through the asset pipeline:

```javascript
//= require message-bus
```

In your application Javascript, you can then subscribe to particular channels and define callback functions to be executed when messages are received:

```javascript
MessageBus.start(); // call once at startup

// how often do you want the callback to fire in ms
MessageBus.callbackInterval = 500;

// you will get all new messages sent to channel
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
});

// you will get all new messages sent to channel (-1 is implicit)
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
}, -1);

// all messages AFTER message id 7 AND all new messages
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
}, 7);

// last 2 messages in channel AND all new messages
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
}, -3);
```

#### JavaScript Client settings

All client settings are settable via `MessageBus.OPTION`

Setting|Default|Info
----|---|---|
enableLongPolling|true|Allow long-polling (provided it is enabled by the server)
callbackInterval|15000|Safeguard to ensure background polling does not exceed this interval (in milliseconds)
backgroundCallbackInterval|60000|Interval to poll when long polling is disabled (either explicitly or due to browser being in background)
minPollInterval|100|When polling requests succeed, this is the minimum amount of time to wait before making the next request.
maxPollInterval|180000|If request to the server start failing, MessageBus will backoff, this is the upper limit of the backoff.
alwaysLongPoll|false|For debugging you may want to disable the "is browser in background" check and always long-poll
baseUrl|/|If message bus is mounted at a sub-path or different domain, you may configure it to perform requests there
ajax|$.ajax falling back to XMLHttpRequest|MessageBus will first attempt to use jQuery and then fallback to a plain XMLHttpRequest version that's contained in the `message-bus-ajax.js` file. `message-bus-ajax.js` must be loaded after `message-bus.js` for it to be used. You may override this option with a function that implements an ajax request by some other means
headers|{}|Extra headers to be include with requests. Properties and values of object must be valid values for HTTP Headers, i.e. no spaces or control characters.
minHiddenPollInterval|1500|Time to wait between poll requests performed by background or hidden tabs and windows, shared state via localStorage
enableChunkedEncoding|true|Allows streaming of message bus data over the HTTP connection without closing the connection after each message.

#### Javascript Client API

`MessageBus.start()` : Starts up the MessageBus poller

`MessageBus.subscribe(channel,func,lastId)` : Subscribes to a channel. You may optionally specify the id of the last message you received in the channel. The callback receives three arguments on message delivery: `func(payload, globalId, messageId)`. You may save globalId or messageId of received messages and use then at a later time when client needs to subscribe, receiving the backlog since that id.

`MessageBus.unsubscribe(channel,func)` : Removes a subscription from a particular channel that was defined with a particular callback function (optional).

`MessageBus.pause()` : Pauses all MessageBus activity

`MessageBus.resume()` : Resumes MessageBus activity

`MessageBus.stop()` : Stops all MessageBus activity

`MessageBus.status()` : Returns status (started, paused, stopped)

`MessageBus.noConflict()` : Removes MessageBus from the global namespace by replacing it with whatever was present before MessageBus was loaded. Returns a reference to the MessageBus object.

`MessageBus.diagnostics()` : Returns a log that may be used for diagnostics on the status of message bus.

#### Ruby

The gem ships with a Ruby implementation of the client library available with an
API very similar to that of the JavaScript client. It was inspired by
https://github.com/lowjoel/message_bus-client.

```ruby
# Creates a client with the default configuration
client = MessageBus::HTTPClient.new('http://some.test.com')

# Listen for the latest messages
client.subscribe("/channel") { |data| puts data }

# Listen for all messages after id 7
client.subscribe("/channel", last_message_id: 7) { |data| puts data }

# Listen for last message and all new messages
client.subscribe("/channel", last_message_id: -2) { |data| puts data }

# Unsubscribe from a channel
client.unsubscribe("/channel")

# Unsubscribe a particular callback from a channel
callback = -> { |data| puts data }
client.subscribe("/channel", &callback)
client.unsubscribe("/channel", &callback)
```

#### Ruby Client Settings

Setting|Default|Info
----|---|---|
enable_long_polling|true|Allow long-polling (provided it is enabled by the server)
background_callback_interval|60s|Interval to poll when long polling is disabled
min_poll_interval|0.1s|When polling requests succeed, this is the minimum amount of time to wait before making the next request.
max_poll_interval|180s|If request to the server start failing, MessageBus will backoff, this is the upper limit of the backoff.
enable_chunked_encoding|true|Allows streaming of message bus data over the HTTP connection without closing the connection after each message.
headers|{}|Extra headers to be include with requests. Properties and values of object must be valid values for HTTP Headers, i.e. no spaces or control characters.


## Configuration

message_bus can be configured to use one of several available storage backends, and each has its own configuration options.

### Redis

message_bus supports using Redis as a storage backend, and you can configure message_bus to use redis in `config/initializers/message_bus.rb`, like so:

```ruby
MessageBus.configure(backend: :redis, url: "redis://:p4ssw0rd@10.0.1.1:6380/15")
```

The redis client message_bus uses is [redis-rb](https://github.com/redis/redis-rb), so you can visit it's repo to see what other options you can pass besides a `url`.

#### Data Retention

Out of the box Redis keeps track of 2000 messages in the global backlog and 1000 messages in a per-channel backlog. Per-channel backlogs get cleared automatically after 7 days of inactivity.

This is configurable via accessors on the ReliablePubSub instance.

```ruby
# only store 100 messages per channel
MessageBus.reliable_pub_sub.max_backlog_size = 100

# only store 100 global messages
MessageBus.reliable_pub_sub.max_global_backlog_size = 100

# flush per-channel backlog after 100 seconds of inactivity
MessageBus.reliable_pub_sub.max_backlog_age = 100
```

### PostgreSQL

message_bus also supports PostgreSQL as a backend, and can be configured like so:

```ruby
MessageBus.configure(backend: :postgres, backend_options: {user: 'message_bus', dbname: 'message_bus'})
```

The PostgreSQL client message_bus uses is [ruby-pg](https://bitbucket.org/ged/ruby-pg), so you can visit it's repo to see what options you can include in `:backend_options`.

A `:clear_every` option is also supported, which limits backlog trimming frequency to the specified number of publications. If you set `clear_every: 100`, the backlog will only be cleared every 100 publications. This can improve performance in cases where exact backlog length limiting is not required.

### Memory

message_bus also supports an in-memory backend. This can be used for testing or simple single-process environments that do not require persistence or horizontal scalability.

```ruby
MessageBus.configure(backend: :memory)
```

The `:clear_every` option supported by the PostgreSQL backend is also supported by the in-memory backend.

### Forking/threading app servers

If you're using a forking or threading app server and you're not getting immediate delivery of published messages, you might need to configure your web server to re-connect to the message_bus backend

#### Passenger

```ruby
# Rails: config/application.rb or config.ru
if defined?(PhusionPassenger)
  PhusionPassenger.on_event(:starting_worker_process) do |forked|
    if forked
      # We're in smart spawning mode.
      MessageBus.after_fork
    else
      # We're in conservative spawning mode. We don't need to do anything.
    end
  end
end
```

MessageBus uses long polling which needs to be configured in Passenger

For passenger version < 5.0.21, add the following to `application.rb`:

```ruby
PhusionPassenger.advertised_concurrency_level = 0
```

For passenger version > 5.0.21, add the following to `nginx.conf`:

```
location /message-bus {
  passenger_app_group_name foo_websocket;
  passenger_force_max_concurrent_requests_per_process 0;
}
```

For more information see the [Passenger documentation](https://www.phusionpassenger.com/library/config/nginx/tuning_sse_and_websockets/) on long-polling.

#### Puma

```ruby
# path/to/your/config/puma.rb
require 'message_bus' # omit this line for Rails 5
on_worker_boot do
  MessageBus.after_fork
end
```

#### Unicorn

```ruby
# path/to/your/config/unicorn.rb
require 'message_bus'
after_fork do |server, worker|
  MessageBus.after_fork
end
```

### Middleware stack in Rails

MessageBus middleware has to show up after the session middleware, but depending on how the Rails app is configured that might be either `ActionDispatch::Session::CookieStore` or `ActionDispatch::Session::ActiveRecordStore`. To handle both cases, the middleware is inserted before `ActionDispatch::Flash`.

For APIs or apps that have `ActionDispatch::Flash` deleted from the stack the middleware is pushed to the bottom.

Should you wish to manipulate the default behavior please refer to [Rails MiddlewareStackProxy documentation](http://api.rubyonrails.org/classes/Rails/Configuration/MiddlewareStackProxy.html) and alter the order of the middlewares in stack in `app/config/initializers/message_bus.rb`

```ruby
# config/initializers/message_bus.rb
Rails.application.config do |config|
  # do anything you wish with config.middleware here
end
```

Specifically, if you use a Rack middleware-based authentication solution (such as Warden) in a Rails application and wish to use it for authenticating message_bus requests, you must ensure that the MessageBus middleware comes after it in the stack. Unfortunately, this can be difficult, but the following solution is known to work:

```ruby
# config/initializers/message_bus.rb
Rails.application.config do |config|
  # See https://github.com/rails/rails/issues/26303#issuecomment-442894832
  MyAppMessageBusMiddleware = Class.new(MessageBus::Rack::Middleware)
  config.middleware.delete(MessageBus::Rack::Middleware)
  config.middleware.insert_after(Warden::Manager, MyAppMessageBusMiddleware)
end
```

### A Distributed Cache

MessageBus ships with an optional `DistributedCache` API which provides a simple and efficient way of synchronizing a cache between processes, based on the core of message_bus:

```ruby
require 'message_bus/distributed_cache'

# process 1

cache = MessageBus::DistributedCache.new("animals")

# process 2

cache = MessageBus::DistributedCache.new("animals")

# process 1

cache["frogs"] = 5

# process 2

puts cache["frogs"]
# => 5

cache["frogs"] = nil

# process 1

puts cache["frogs"]
# => nil
```

You can automatically expire the cache on application code changes by scoping the cache to a specific version of the application:

```ruby
cache = MessageBus::DistributedCache.new("cache name", app_version: "12.1.7.ABDEB")
cache["a"] = 77

cache = MessageBus::DistributedCache.new("cache name", app_version: "12.1.7.ABDEF")

puts cache["a"]
# => nil
```

#### Error Handling

The internet is a chaotic environment and clients can drop off for a variety of reasons. If this happens while message_bus is trying to write a message to the client you may see something like this in your logs:

```
Errno::EPIPE: Broken pipe
  from message_bus/client.rb:159:in `write'
  from message_bus/client.rb:159:in `write_headers'
  from message_bus/client.rb:178:in `write_chunk'
  from message_bus/client.rb:49:in `ensure_first_chunk_sent'
  from message_bus/rack/middleware.rb:150:in `block in call'
  from message_bus/client.rb:21:in `block in synchronize'
  from message_bus/client.rb:21:in `synchronize'
  from message_bus/client.rb:21:in `synchronize'
  from message_bus/rack/middleware.rb:147:in `call'
  ...
```

The user doesn't see anything, but depending on your traffic you may acquire quite a few of these in your logs or exception tracking tool.

You can rescue from errors that occur in MessageBus's middleware stack by adding a config option:

```ruby
MessageBus.configure(on_middleware_error: proc do |env, e|
  # env contains the Rack environment at the time of error
  # e contains the exception that was raised
  if Errno::EPIPE === e
    [422, {}, [""]]
  else
    raise e
  end
end)
```

## How it works

MessageBus provides durable messaging following the publish-subscribe (pubsub) pattern to subscribers who track their own subscriptions. Durability is by virtue of the persistence of messages in backlogs stored in the selected backend implementation (Redis, Postgres, etc) which can be queried up until a configurable expiry. Subscribers must keep track of the ID of the last message they processed, and request only more-recent messages in subsequent connections.

The MessageBus implementation consists of several key parts:

* Backend implementations - these provide a consistent API over a variety of options for persisting published messages. The API they present is around the publication to and reading of messages from those backlogs in a manner consistent with message_bus' philosophy. Each of these inherits from `MessageBus::Backends::Base` and implements the interface it documents.
* `MessageBus::Rack::Middleware` - which accepts requests from subscribers, validates and authenticates them, delivers existing messages from the backlog and informs a `MessageBus::ConnectionManager` of a connection which is remaining open.
* `MessageBus::ConnectionManager` - manages a set of subscribers with active connections to the server, such that messages which are published during the connection may be dispatched.
* `MessageBus::Client` - represents a connected subscriber and delivers published messages over its connected socket.
* `MessageBus::Message` - represents a published message and its encoding for persistence.

The public API is all defined on the `MessageBus` module itself.

### Subscriber protocol

The message_bus protocol for subscribing clients is based on HTTP, optionally with long-polling and chunked encoding, as specified by the HTTP/1.1 spec in RFC7230 and RFC7231.

The protocol consists of a single HTTP end-point at `/message-bus/[client_id]/poll`, which responds to `POST` and `OPTIONS`. In the course of a `POST` request, the client must indicate the channels from which messages are desired, along with the last message ID the client received for each channel, and an incrementing integer sequence number for each request (used to detect out of order requests and close those with the same client ID and lower sequence numbers).

Clients' specification of requested channels can be submitted in either JSON format (with a `Content-Type` of `application/json`) or as HTML form data (using `application/x-www-form-urlencoded`). An example request might look like:

```
POST /message-bus/3314c3f12b1e45b4b1fdf1a6e42ba826/poll HTTP/1.1
Host: foo.com
Content-Type: application/json
Content-Length: 37

{"/foo/bar":3,"/doo/dah":0,"__seq":7}
```

If there are messages more recent than the client-specified IDs in any of the requested channels, those messages will be immediately delivered to the client. If the server is configured for long-polling, the client has not requested to disable it (by specifying the `dlp=t` query parameter), and no new messages are available, the connection will remain open for the configured long-polling interval (25 seconds by default); if a message becomes available in that time, it will be delivered, else the connection will close. If chunked encoding is enabled, message delivery will not automatically end the connection, and messages will be continuously delivered during the life of the connection, separated by `"\r\n|\r\n"`.

The format for delivered messages is a JSON array of message objects like so:

```json
[
  {
    "global_id": 12,
    "message_id": 1,
    "channel": "/some/channel/name",
    "data": [the message as published]
  }
]
```

The `global_id` field here indicates the ID of the message in the global backlog, while the `message_id` is the ID of the message in the channel-specific backlog. The ID used for subscriptions is always the channel-specific one.

In certain conditions, a status message will be delivered and look like this:

```json
{
  "global_id": -1,
  "message_id": -1,
  "channel": "/__status",
  "data": {
    "/some/channel":5,
    "/other/channel":9
  }
}
```

This message indicates the last ID in the backlog for each channel that the client subscribed to. It is sent in the following circumstances:

* When the client subscribes to a channel starting from `-1`. When long-polling, this message will be delivered immediately.
* When the client subscribes to a channel starting from a message ID that is beyond the last message on that channel.
* When delivery of messages to a client is skipped because the message is filtered to other users/groups.

The values provided in this status message can be used by the client to skip requesting messages it will never receive and move forward in polling.

### Publishing to MessageBus from outside of MessageBus

It may be necessary or desired for integration with existing systems to publish messages from outside the Ruby app where MessageBus is running. @tgodfrey has an example of how to do that, using the Redis backend, from Elixir here: https://gist.github.com/tgodfrey/1a67753d51cb202ca8eb04b933cec924.

## Contributing

If you are looking to contribute to this project here are some ideas

- MAKE THIS README BETTER!
- Build backends for other providers (zeromq, rabbitmq, disque) - currently we support pg and redis.
- Improve and properly document admin dashboard (add opt-in stats, better diagnostics into queues)
- Improve general documentation (Add examples, refine existing examples)
- Make MessageBus a nice website
- Add optional transports for websocket and shared web workers

When submitting a PR, please be sure to include notes on it in the `Unreleased` section of the changelog, but do not bump the version number.

### Running tests

To run tests you need both Postgres and Redis installed. By default on Redis the tests connect to `localhost:6379` and on Postgres connect the database `localhost:5432/message_bus_test` with the system username; if you wish to override this, you can set alternative values:

```
PGUSER=some_user PGDATABASE=some_db bundle exec rake
```

We include a Docker Compose configuration to run test suite in isolation, or if you do not have Redis or Postgres installed natively. To execute it, do `docker-compose run tests`.

### Generating the documentation

Run `rake yard` (or `docker-compose run docs rake yard`) in order to generate the implementation's API docs in HTML format, and `open doc/index.html` to view them.

While working on documentation, it is useful to automatically re-build it as you make changes. You can do `yard server --reload` (or `docker-compose up docs`) and `open http://localhost:8808` to browse live-built docs as you edit them.

### Benchmarks

Some simple benchmarks are implemented in `spec/performance` and can be executed using `rake performance` (or `docker-compose run tests rake performance`). You should run these before and after your changes to avoid introducing performance regressions.

### Diagnostics Interface

It is possible to manually test the diagnostics interface by executing `docker-compose up example` and then `open http://localhost:9292`.
