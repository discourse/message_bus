require 'message_bus'
require 'sinatra'
require 'sinatra/base'

class Chat < Sinatra::Base

  use MessageBus::Rack::Middleware

  get '/' do
    'hello world'
  end

  run! if app_file == $0
end
