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
    <style>
        #panel { position: fixed; bottom: 0; background-color: #FFFFFF; }
        #messages { padding-bottom: 40px; }
        .hidden { display: none; }
    </style>
  </head>
  <body>
    <p>This is a trivial chat demo... It is implemented as a <a href="https://github.com/SamSaffron/message_bus/blob/master/examples/chat/chat.rb">Sinatra app</a>. The <a href="https://github.com/SamSaffron/message_bus">message_bus</a> can easily be added to any Rails/Rack app. <small>This app can be deployed with <a href="https://github.com/discourse/discourse_docker">Discourse Docker</a> using <a href="https://github.com/SamSaffron/message_bus/blob/master/examples/chat/docker_container/chat.yml">this template</a>.</small></p>
    <div id='messages' class="hidden"></div>
    <div id='panel' class="hidden">
      <form>
        <textarea cols=80 rows=2></textarea>
        <button id="send">send</button>
      </form>
    </div>
    <div id='your-name'>Enter your name: <input type='text'/>

    <script>
      $(function() {
        var name;

        $('#messages, #panel').addClass('hidden');

        $('#your-name input').keyup(function(e){
          if(e.keyCode == 13) {
            name = $(this).val();
            $('#your-name').addClass('hidden');
            $('#messages, #panel').removeClass('hidden');
            $('#send').text("send (" + name + ")");
          }
        });

        var safe = function(html){
           return String(html).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        };

        MessageBus.subscribe("/message", function(msg){
          $('#messages').append("<p>"+ safe(msg.name) + " said: " + safe(msg.data) + "</p>");
          $(document.body).scrollTop(document.body.scrollHeight);
        }, 0); // last id is zero, so getting backlog

        var submit = function(){
          var val = $('form textarea').val().trim();
          if (val.length === 0) {
            return;
          }
          $.post("/message", { data: val, name: name} );
          $('textarea').val("");
        };

        $('#send').click(function(){submit(); return false;});

        $('textarea').keyup(function(e){
          if(e.keyCode == 13) {
            submit();
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
