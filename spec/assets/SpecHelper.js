/* global beforeEach, afterEach, it, spyOn, MessageBus */

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
    for (var j=0;j<chunks.length;j++) {
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
  }

  MockedXMLHttpRequest.prototype.send              = function(){
    this.readyState = 4
    this.responseText = encodeChunks(this, spec.responseChunks);
    this.status = spec.responseStatus;

    spec.requestStarted?.();

    const complete = () => {
      if(this.statusText === "abort"){
        return;
      }
      this.onprogress?.();
      this.onreadystatechange();
    }

    if(spec.delayResponsePromise){
      spec.delayResponsePromise.then(() => complete())
      spec.delayResponsePromise = null;
    }else{
      complete();
    }
  }

  MockedXMLHttpRequest.prototype.open              = function(){ }

  MockedXMLHttpRequest.prototype.abort             = function(){
    this.readyState = 4
    this.responseText = '';
    this.statusText = 'abort';
    this.status = 0;
    this.onreadystatechange()
  }

  MockedXMLHttpRequest.prototype.setRequestHeader  = function(k,v){
    this.headers[k] = v;
  }

  MockedXMLHttpRequest.prototype.getResponseHeader = function(headerName){
    return spec.responseHeaders[headerName];
  }

  MessageBus.xhrImplementation = MockedXMLHttpRequest
  this.MockedXMLHttpRequest = MockedXMLHttpRequest

  this.responseChunks = [
    {channel: '/test', data: {password: 'MessageBusRocks!'}}
  ];

  this.responseStatus = 200;
  this.responseHeaders = {
    "Content-Type": 'text/plain; charset=utf-8',
  };

  MessageBus.enableChunkedEncoding = true;
  MessageBus.firstChunkTimeout = 3000;
  MessageBus.retryChunkedAfterRequests = 1;

  MessageBus.start();
});

afterEach(function(){
  MessageBus.stop()
  MessageBus.callbacks.splice(0, MessageBus.callbacks.length)
  MessageBus.shouldLongPollCallback = null;
});

window.testMB = function(description, testFn, path, data){
  this.responseChunks = [
    {channel: path || '/test', data: data || {password: 'MessageBusRocks!'}}
  ];
  it(description, function(done){
    var spec = this;
    var promisy = {
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
