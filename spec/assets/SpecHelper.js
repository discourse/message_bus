var message_id = 1;
var SEPARATOR = "\r\n|\r\n";

var encodeChunks = function(xhr, chunks) {
  if (!chunks || !chunks.length){
    return '';
  }
  for (var i=0;i<chunks.length;i++) {
    var chunk = chunks[i];
    chunk.global_id = Math.random() * 10000 | 0;
    chunk.message_id = message_id++;
  }
  if (xhr.onprogress){ // using longPoll if onprogress is set
    var responses = []
    for (var i=0;i<chunks.length;i++) {
      responses.push( JSON.stringify([chunk]) );
    }
    return responses.join(SEPARATOR) + SEPARATOR;
  } else {
    return chunks;
  }
}

beforeEach(function () {
  var spec = this;

  function MockedXMLHttpRequest(){
    this.headers = {};
  };
  MockedXMLHttpRequest.prototype.send              = function(){
    this.readyState = 4
    this.responseText = encodeChunks(this, spec.responseChunks);
    this.statusText = 'OK';
    this.status = 200;
    if (this.onprogress){ this.onprogress(); }
    this.onreadystatechange()
  }
  MockedXMLHttpRequest.prototype.open              = function(){ }
  MockedXMLHttpRequest.prototype.abort             = function(){ }
  MockedXMLHttpRequest.prototype.setRequestHeader  = function(k,v){
    this.headers[k] = v;
  }
  MockedXMLHttpRequest.prototype.getResponseHeader = function(){
    return 'text/plain; charset=utf-8';
  }
  MessageBus.xhrImplementation = MockedXMLHttpRequest
  this.MockedXMLHttpRequest = MockedXMLHttpRequest
  MessageBus.start()
  this.responseChunks = [
    {channel: '/test', data: {password: 'MessageBusRocks!'}}
  ];

});

window.testMB = function(description, testFn, path, data){
  this.responseChunks = [
    {channel: path || '/test', data: data || {password: 'MessageBusRocks!'}}
  ];
  it(description, function(done){
    spec = this;
    promisy = {
      finally: function(fn){
        this.resolve = fn;
      }
    }
    this.perform = function(specFn){
      var xhrRequest = null;
      spyOn(this.MockedXMLHttpRequest.prototype, 'open').and.callFake(function(method, url){
        xhrRequest = this;
        xhrRequest.url = url
        xhrRequest.method = method
        spec.MockedXMLHttpRequest.prototype.open.and.callThrough(this, method, url);
      })
      MessageBus.subscribe(path || '/test', function(message){
        try {
          specFn.call(spec, message, xhrRequest);
        } catch( error ){
          promisy.resolve.call(spec);
          throw(error);
        }
        promisy.resolve.call(spec);
        done();
      });
      return promisy;
    };
    testFn.call(this);
  });

}

afterEach(function(){
  MessageBus.stop()
  if (MessageBus.longPoll){
    MessageBus.longPoll.abort();
  }
  MessageBus.callbacks.splice(0, MessageBus.callbacks.length)
});
