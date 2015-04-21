$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)
require 'message_bus'
require 'sinatra'
require 'sinatra/base'


class Chat < Sinatra::Base

  set :public_folder,  File.expand_path('../../../assets',__FILE__)

  use MessageBus::Rack::Middleware

  post '/message' do
    MessageBus.publish '/message', params

    "OK"
  end

  get '/' do

<<HTML

<html>
  <head>
    <script src="/jquery-1.8.2.js"></script>
    <script src="/message-bus.js"></script>
  </head>
  <body>
    <p>This is a trivial chat demo, it is implemented as a <a href="https://github.com/SamSaffron/message_bus/blob/master/examples/chat/chat.rb">Sinatra app</a>. The <a href="https://github.com/SamSaffron/message_bus">message_bus</a> can easily be added to any Rails/Rack app. <small>This app can be deployed with <a href="https://github.com/discourse/discourse_docker">Discourse Docker</a> using <a href="https://github.com/SamSaffron/message_bus/blob/master/examples/chat/docker_container/chat.yml">this template</a>.</small></p>
    <div id='messages'></div>
    <div id='panel'>
      <form>
        <textarea cols=80 rows=2></textarea>
      </form>
    </div>
    <div id='your-name'>Enter your name: <input type='text'/>

    <script>
      $(function() {
        var name;

        $('#messages, #panel').hide();

        $('#your-name input').keyup(function(e){
          if(e.keyCode == 13) {
            name = $(this).val();
            $('#your-name').hide();
            $('#messages, #panel').show();
          }
        });


        MessageBus.subscribe("/message", function(msg){
          $('#messages').append("<p>"+ escape(msg.name) + " said: " + escape(msg.data) + "</p>");
        }, 0); // last id is zero, so getting backlog


        $('textarea').keyup(function(e){
          if(e.keyCode == 13) {
            $.post("/message", { data: $('form textarea').val(), name: name} );
            $('textarea').val("");
          }
        });

      });
    </script>
  </body>
</html>

HTML
  end

  run! if app_file == $0
end
