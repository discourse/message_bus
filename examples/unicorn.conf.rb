require 'message_bus'
after_fork do |server, worker|
  MessageBus.after_fork
end
