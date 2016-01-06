require 'message_bus'
on_worker_boot do
  MessageBus.after_fork
end
