# MessageBus

A reliable, robust messaging bus for Ruby processes and web clients built on Redis.

MessageBus implements a Server to Server channel based protocol and Server to Web Client protocol (using polling, long-polling or long-polling + streaming)

Long-polling is implemented using Rack Hijack and Thin::Async, all common Ruby web server can run MessageBus (Thin, Puma, Unicorn) and handle a large amount of concurrent connections that wait on messages.

MessageBus is implemented as Rack middleware and can be used by and Rails / Sinatra or pure Rack application.

# Try it out!

Live chat demo per [examples/chat](https://github.com/SamSaffron/message_bus/tree/master/examples/chat) is at:

### http://chat.samsaffron.com

## Can you handle concurrent requests?

**Yes**, MessageBus uses Rack Hijack, this interface allows us to take control of the underlying socket. MessageBus can handle thousands of concurrent long polls on all popular Ruby webservers. MessageBus runs as middleware in your Rack (or by extension Rails) application and does not require a dedicated server. Background work is minimized to ensure it does not interfere with existing non MessageBus traffic.

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

MessageBus.backlog "/channel", id
# returns all messages after the id

# messages can be targetted at particular users or groups
MessageBus.publish "/channel", "hello", user_ids: [1,2,3], group_ids: [4,5,6]

# messages can be targetted at particular clients (using MessageBus.clientId)
MessageBus.publish "/channel", "hello", client_ids: ["XXX","YYY"]

# message bus determines the user ids and groups based on env

MessageBus.user_id_lookup do |env|
  # return the user id here
end

MessageBus.group_ids_lookup do |env|
  # return the group ids the user belongs to
  # can be nil or []
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
MessageBus.chunked_encoding_enabled = false // in Ruby
```

Long Polling requires no special setup, as soon as new data arrives on the channel the server delivers the data and closes the connection.

Polling also requires no special setup, MessageBus will fallback to polling after a tab becomes inactive and remains inactive for a period.

### Multisite support

MessageBus can be used in an environment that hosts multiple sites by multiplexing channels. To use this mode

```ruby
# define a site_id lookup method
MessageBus.site_id_lookup do
  some_method_that_returns_site_id_string
end

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

**Client settings**:


All client settings are settable via `MessageBus.OPTION`

Setting|Default|
----|---|---|
enableLongPolling|true|Allow long-polling (provided it is enable by the server)
callbackInterval|15000|Safeguard to ensure background polling does not exceed this interval (in milliseconds)
backgroundCallbackInterval|60000|Interval to poll when long polling is disabled (either explicitly or due to browser being in backgroud)
maxPollInterval|180000|If request to the server start failing, MessageBus will backoff, this is the upper limit of the backoff.
alwaysLongPoll|false|For debugging you may want to disable the "is browser in background" check and always long-poll
baseUrl|/|If message bus is mounted in a subdirectory of different domain, you may configure it to perform requests there
ajax|$.ajax|The only dependency on jQuery, you may set up a custom ajax function here

**API**:

`MessageBus.diagnostics()` : Returns a log that may be used for diagnostics on the status of message bus

`MessageBus.pause()` : Pause all MessageBus activity

`MessageBus.resume()` : Resume MessageBus activity

`MessageBus.stop()` : Stop all MessageBus activity

`MessageBus.start()` : Must be called to startup the MessageBus poller

`MessageBus.subscribe(channel,func,lastId)` : Subscribe to a channel, optionally you may specify the id of the last message you received in the channel.

`MessageBus.unsubscribe(channel,func)` : Unsubscribe callback from a particular channel



## Configuration

### Redis

You can configure redis setting in `config/initializers/message_bus.rb`, like

```ruby
MessageBus.redis_config = { url: "redis://:p4ssw0rd@10.0.1.1:6380/15" }
```
The redis client message_bus uses is [redis-rb](https://github.com/redis/redis-rb), so you can visit it's repo to see what options you can configure.

### Forking/threading app servers

If you're using a forking or threading app server and you're not getting immediate updates from published messages, you might need to reconnect Redis in your app server config:

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

#### Puma
```ruby
# path/to/your/config/puma.rb
require 'message_bus'
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

## Want to help?

If you are looking to contribute to this project here are some ideas

- Build an in-memory storage backend to ease testing and for very simple deployments
- Build a PostgreSQL backend using NOTIFY and LISTEN
- Improve general documentation
- Port the test suite to MiniTest
- Make MessageBus a nice website


