# MessageBus

A reliable, robust messaging bus for Ruby processes and web clients built on Redis.

MessageBus implements a Server to Server channel based protocol and Server to Web Client protocol (using polling or long-polling)


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
  # block called in a backgroud thread when message is recieved
end

MessageBus.backlog "/channel", id
# returns all messages after the id


# messages can be targetted at particular users or groups
MessageBus.publish "/channel", user_ids: [1,2,3], group_ids: [4,5,6]

# message bus determines the user ids and groups based on env

MessageBus.user_id_lookup do |env|
  # return the user id here
end

MessageBus.group_ids_lookup do |env|
  # return the group ids the user belongs to
  # can be nil or []
end


MessageBus.client_filter("/channel") do |user_id, message|
  # return message if client is allowed to see this message
  # allows you to inject server side filtering of messages based on arbitrary rules
  # also allows you to override the message a client will see
  # be sure to .dup the message if you wish to change it
end

```

JavaScript can listen on any channel (and receive notification via polling or long polling):

```html
<script src="message-bus.js" type="text/javascript"></script>
```
Note, the message-bus.js file is located in the assets folder.

```javascript
MessageBus.start(); // call once at startup

// how often do you want the callback to fire in ms
MessageBus.callbackInterval = 500;
MessageBus.subscribe("/channel", function(data){
  // data shipped from server
}


```


## Similar projects

Faye - http://faye.jcoglan.com/

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
