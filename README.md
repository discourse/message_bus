# MessageBus

A reliable, robust messaging bus for Ruby processes and web clients.

MessageBus implements a Server to Server channel based protocol and Server to Web Client protocol (using polling, long-polling or long-polling + streaming)

Long-polling is implemented using Rack Hijack and Thin::Async, all common Ruby web server can run MessageBus (Thin, Puma, Unicorn) and handle a large amount of concurrent connections that wait on messages.

MessageBus is implemented as Rack middleware and can be used by and Rails / Sinatra or pure Rack application.

# Try it out!

Live chat demo per [examples/chat](https://github.com/SamSaffron/message_bus/tree/master/examples/chat) is at:

### http://chat.samsaffron.com

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

```
MessageBus.enableChunkedEncoding = false; // in your JavaScript
```

Or

```
MessageBus.configure(chunked_encoding_enabled: false) // in Ruby
```

Long Polling requires no special setup, as soon as new data arrives on the channel the server delivers the data and closes the connection.

Polling also requires no special setup, MessageBus will fallback to polling after a tab becomes inactive and remains inactive for a period.

### Multisite support

MessageBus can be used in an environment that hosts multiple sites by multiplexing channels. To use this mode

```ruby
# define a site_id lookup method
MessageBus.configure(site_id_lookup: proc do
  some_method_that_returns_site_id_string
end)

# you may post messages just to this site
MessageBus.publish "/channel", "some message"

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
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
});

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
backgroundCallbackInterval|60000|Interval to poll when long polling is disabled (either explicitly or due to browser being in backgroud)
maxPollInterval|180000|If request to the server start failing, MessageBus will backoff, this is the upper limit of the backoff.
alwaysLongPoll|false|For debugging you may want to disable the "is browser in background" check and always long-poll
baseUrl|/|If message bus is mounted in a subdirectory of different domain, you may configure it to perform requests there
ajax|$.ajax or XMLHttpRequest|MessageBus will first attempt to use jQuery and then fallback to a plain XMLHttpRequest version that's contained in the `messsage-bus-ajax.js` file. `messsage-bus-ajax.js` must be loaded after `messsage-bus.js` for it to be used.
headers|{}|Extra headers to be include with request.  Properties and values of object must be valid values for HTTP Headers, i.e. no spaces and control characters.
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

To run tests you need both Postgres and Redis installed. By default we will connect to the database `message_bus_test` with the current username. If you wish to override this:

```
PGUSER=some_user PGDATABASE=some_db bundle exec rake
```


## Configuration

### Redis

You can configure redis setting in `config/initializers/message_bus.rb`, like

```ruby
MessageBus.configure(backend: :redis, url: "redis://:p4ssw0rd@10.0.1.1:6380/15")
```
The redis client message_bus uses is [redis-rb](https://github.com/redis/redis-rb), so you can visit it's repo to see what options you can configure.

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

###

## Want to help?

If you are looking to contribute to this project here are some ideas

- Add a test suite for JavaScript message-bus.js
- Build backends for other providers (zeromq, rabbitmq, disque)
- Improve and properly document admin dashboard (add opt-in stats, better diagnostics into queues)
- Improve general documentation (Add examples, refine existing examples)
- Make MessageBus a nice website
