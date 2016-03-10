var message_id = 1;
var SEPARATOR = "\r\n|\r\n";

var encodeChunks = function(chunks) {
  var responses = []
  for (var i=0;i<chunks.length;i++) {
    var chunk = chunks[i];
    chunk.global_id = Math.random() * 10000 | 0;
    chunk.message_id = message_id++;
    responses.push( JSON.stringify([chunk]) );
  }
  return responses.join(SEPARATOR) + SEPARATOR;
}

beforeEach(function () {
    var spec = this;

    function MockedXMLHttpRequest(){ }
    MockedXMLHttpRequest.prototype.open              = function(){ }
    MockedXMLHttpRequest.prototype.send              = function(){
      this.readyState = 4
      this.responseText = spec.responseChunks ? encodeChunks(spec.responseChunks) : ''
      this.statusText = 'OK'
      this.onprogress()
      this.onreadystatechange()
    }
    MockedXMLHttpRequest.prototype.abort             = function(){ }
    MockedXMLHttpRequest.prototype.setRequestHeader  = function(){ }
    MockedXMLHttpRequest.prototype.getResponseHeader = function(){ }
    MessageBus.XMLHttpRequest = MockedXMLHttpRequest
    this.MockedXMLHttpRequest = MockedXMLHttpRequest
    MessageBus.start()


  // jasmine.addMatchers({
  //   toBePlaying: function () {
  //     return {
  //       compare: function (actual, expected) {
  //         var player = actual;

  //         return {
  //           pass: player.currentlyPlayingSong === expected && player.isPlaying
  //         };
  //       }
  //     };
  //   }
  // });
});


afterEach(function(){
  MessageBus.stop()
  if (MessageBus.longPoll){
    MessageBus.longPoll.abort();
  }
  MessageBus.callbacks.splice(0, MessageBus.callbacks.length)
});
