# MessageBus

A reliable, robust messaging bus for Ruby processes and web clients.

MessageBus implements a Server to Server channel based protocol and Server to Web Client protocol (using polling, long-polling or long-polling + streaming)

Long-polling is implemented using Rack Hijack and Thin::Async, all common Ruby web server can run MessageBus (Thin, Puma, Unicorn) and handle a large amount of concurrent connections that wait on messages.

MessageBus is implemented as Rack middleware and can be used by and Rails / Sinatra or pure Rack application.

# Try it out!

Live chat demo per [examples/chat](https://github.com/SamSaffron/message_bus/tree/master/examples/chat) is at:

### http://chat.samsaffron.com

## Want to help?

If you are looking to contribute to this project here are some ideas

- MAKE THIS README BETTER!
- Build backends for other providers (zeromq, rabbitmq, disque) - currently we support pg and redis.
- Improve and properly document admin dashboard (add opt-in stats, better diagnostics into queues)
- Improve general documentation (Add examples, refine existing examples)
- Make MessageBus a nice website
- Add optional transports for websocket and shared web workers

## Ruby version support

MessageBus only support officially supported versions of Ruby, as of [2018-06-20](https://www.ruby-lang.org/en/news/2018/06/20/support-of-ruby-2-2-has-ended/) this means we only support Ruby version 2.3 and up.

## Can you handle concurrent requests?

**Yes**, MessageBus uses Rack Hijack, this interface allows us to take control of the underlying socket. MessageBus can handle thousands of concurrent long polls on all popular Ruby webservers. MessageBus runs as middleware in your Rack (or by extension Rails) application and does not require a dedicated server. Background work is minimized to ensure it does not interfere with existing non MessageBus traffic.

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

# last id in a channel
id = MessageBus.last_id("/channel")

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

MessageBus.backlog "/channel", id
# returns all messages after the id

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

MessageBus.configure(on_middleware_error: proc do |env, e|
   # If you wish to add special handling based on error
   # return a rack result array: [status, headers, body]
   # If you just want to pass it on return nil
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

### Debugging

When setting up MessageBus, it's good to manually check the channels before integrating the client.

You can `curl` MessageBus. This is helpful when trying to debug what may be doing wrong. This uses https://chat.samsaffron.com.

```
curl -H "Content-Type: application/x-www-form-urlencoded" -X POST --data "/message=0" https://chat.samsaffron.com/message-bus/client-id/poll\?dlp\=t
```

You should see a reply with the messages of that channel you requested for (`/message`) starting at the message ID (`0`). `dlp=t` disables long-polling: we do not want this request to stay open.

### Transport

MessageBus ships with 3 transport mechanisms.

1. Long Polling with chunked encoding (streaming)
2. Long Polling
3. Polling

Long Polling with chunked encoding allows a single connection to stream multiple messages to a client, this requires HTTP/1.1

Chunked encoding provides all the benefits of [EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource) with greater browser support (as it works on IE10 and up as well)

To setup NGINX to proxy to your app correctly be sure to enable HTTP1.1 and disable buffering

```
location /message-bus/ {
  ...
  proxy_buffering off;
  proxy_http_version 1.1;
  ...
}
```

**NOTE**: do not set proxy_buffering off globally, it may have unintended consequences.

If you wish to disable chunked encoding run:

```ruby
MessageBus.enableChunkedEncoding = false; // in your JavaScript
```

Or

```ruby
MessageBus.configure(chunked_encoding_enabled: false) // in Ruby
```

Long Polling requires no special setup, as soon as new data arrives on the channel the server delivers the data and closes the connection.

Polling also requires no special setup, MessageBus will fallback to polling after a tab becomes inactive and remains inactive for a period.

### Multisite support

MessageBus can be used in an environment that hosts multiple sites by multiplexing channels. To use this mode

```ruby
# define a site_id lookup method, which is executed
# when `MessageBus.publish` is called
MessageBus.configure(site_id_lookup: proc do
  some_method_that_returns_site_id_string
end)

# you may post messages just to this site
MessageBus.publish "/channel", "some message"

# you can also choose to pass the `site_id`.
# This takes precendence over whatever `site_id_lookup`
# returns
MessageBus.publish "/channel", "some message", site_id: "site-id"

# you may publish messages to ALL sites using the /global/ prefix
MessageBus.publish "/global/channel", "will go to all sites"

```

### Client support

MessageBus ships a simple ~300 line JavaScript library which provides an API to interact with the server.


JavaScript can listen on any channel (and receive notification via polling or long polling):

```html
<script src="message-bus.js" type="text/javascript"></script>
```
Note, the message-bus.js file is located in the assets folder.

**Rails**
```javascript
//= require message-bus
```

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

There is also a Ruby implementation of the client library, at
[message_bus-client](https://github.com/lowjoel/message_bus-client) with the API very similar to
that of the JavaScript client.

**Client settings**:


All client settings are settable via `MessageBus.OPTION`

Setting|Default|Info
----|---|---|
enableLongPolling|true|Allow long-polling (provided it is enable by the server)
callbackInterval|15000|Safeguard to ensure background polling does not exceed this interval (in milliseconds)
backgroundCallbackInterval|60000|Interval to poll when long polling is disabled (either explicitly or due to browser being in background)
minPollInterval|100|When polling requests succeed, this is the minimum amount of time to wait before making the next request.
maxPollInterval|180000|If request to the server start failing, MessageBus will backoff, this is the upper limit of the backoff.
alwaysLongPoll|false|For debugging you may want to disable the "is browser in background" check and always long-poll
baseUrl|/|If message bus is mounted in a subdirectory of different domain, you may configure it to perform requests there
ajax|$.ajax or XMLHttpRequest|MessageBus will first attempt to use jQuery and then fallback to a plain XMLHttpRequest version that's contained in the `message-bus-ajax.js` file. `message-bus-ajax.js` must be loaded after `message-bus.js` for it to be used.
headers|{}|Extra headers to be include with request.  Properties and values of object must be valid values for HTTP Headers, i.e. no spaces and control characters.
minHiddenPollInterval|1500|Time to wait between poll requests performed by background or hidden tabs and windows, shared state via localStorage
enableChunkedEncoding|true|Allow streaming of message bus data over the HTTP channel

**API**:

`MessageBus.diagnostics()` : Returns a log that may be used for diagnostics on the status of message bus

`MessageBus.pause()` : Pause all MessageBus activity

`MessageBus.resume()` : Resume MessageBus activity

`MessageBus.stop()` : Stop all MessageBus activity

`MessageBus.start()` : Must be called to startup the MessageBus poller

`MessageBus.status()` : Return status (started, paused, stopped)

`MessageBus.subscribe(channel,func,lastId)` : Subscribe to a channel, optionally you may specify the id of the last message you received in the channel. The callback accepts three arguments: `func(payload, globalId, messageId)`. You may save globalId or messageId of received messages and use then at a later time when client needs to subscribe, receiving the backlog just after that Id.

`MessageBus.unsubscribe(channel,func)` : Unsubscribe callback from a particular channel

`MessageBus.noConflict()` : Removes MessageBus from the global namespace by replacing it with whatever was present before MessageBus was loaded.  Returns a reference to the MessageBus object.

## Running tests

To run tests you need both Postgres and Redis installed. By default on Redis the tests connect to localhost:6379 and on Postgres connect the database `localhost:5432/message_bus_test` with the system username; if you wish to override this, you can set alternative values:

```
PGUSER=some_user PGDATABASE=some_db bundle exec rake
```

We include a Docker Compose configuration to run test suite in isolation, or if you do not have Redis or Postgres installed natively. To execute it, do `docker-compose run tests`.

## Configuration

### Redis

You can configure redis setting in `config/initializers/message_bus.rb`, like

```ruby
MessageBus.configure(backend: :redis, url: "redis://:p4ssw0rd@10.0.1.1:6380/15")
```
The redis client message_bus uses is [redis-rb](https://github.com/redis/redis-rb), so you can visit it's repo to see what options you can configure.

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

message_bus also supports PostgreSQL as the backend:

```ruby
MessageBus.configure(backend: :postgres, backend_options: {user: 'message_bus', dbname: 'message_bus'})
```

The PostgreSQL client message_bus uses is [ruby-pg](https://bitbucket.org/ged/ruby-pg), so you can visit it's repo to see what options you can configure inside `:backend_options`.

A `:clear_every` option is also supported, which only clears the backlogs on every number of requests given.  So if you set `clear_every: 100`, the backlog will only be cleared every 100 requests.  This can improve performance in cases where exact backlog clearing are not required.

### Memory

message_bus also supports an in-memory backend.  This can be used for testing or simple single-process environments that do not require persistence.

```ruby
MessageBus.configure(backend: :memory)
```

The `:clear_every` option supported by the PostgreSQL backend is also supported by the in-memory backend.

### Forking/threading app servers

If you're using a forking or threading app server and you're not getting immediate updates from published messages, you might need to reconnect Redis/PostgreSQL in your app server config:

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

* for passenger version < 5.0.21

`PhusionPassenger.advertised_concurrency_level = 0` to application.rb

* for passenger version > 5.0.21

```
   location /message-bus {
       passenger_app_group_name foo_websocket;
       passenger_force_max_concurrent_requests_per_process 0;
   }
```
to nginx.conf.
For more information see [Passenger documentation](https://www.phusionpassenger.com/library/config/nginx/tuning_sse_and_websockets/)

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

Should you want to manipulate the default behavior please refer to [Rails MiddlewareStackProxy documentation](http://api.rubyonrails.org/classes/Rails/Configuration/MiddlewareStackProxy.html) and alter the order of the middlewares in stack in `app/config/initializers/message_bus.rb`

```ruby
# config/initializers/message_bus.rb
Rails.application.config do |config|
  # do anything you wish with config.middleware here
end
```

### A Distributed Cache

MessageBus ships with an optional DistributedCache object you can use to synchronize a cache between processes.
It allows you a simple and efficient way of synchronizing a cache between processes.

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

Automatically expiring the cache on app update:

```ruby
cache = MessageBus::DistributedCache.new("cache name", app_version: "12.1.7.ABDEB")
cache["a"] = 77

cache = MessageBus::DistributedCache.new("cache name", app_version: "12.1.7.ABDEF")

puts cache["a"]
# => nil
```

#### Error Handling

The internet is a chaotic environment and clients can drop off for a variety of reasons. If this happens while MessageBus is trying to write a message to the client you may see something like this in your logs:

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

The user doesn't see anything, but depending on your traffic you may acquire quite a few of these in your logs.

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
