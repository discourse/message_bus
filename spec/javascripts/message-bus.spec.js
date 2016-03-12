describe("Messagebus", function() {

  it("submits change requests", function(done){
    spyOn(this.MockedXMLHttpRequest.prototype, 'send').and.callThrough();
    this.responseChunks = [
      {channel: '/test', data: 'hi'}
    ];
    var spec = this;
    MessageBus.subscribe('/test', function(){
      expect(spec.MockedXMLHttpRequest.prototype.send)
        .toHaveBeenCalled()
      var req = JSON.parse(spec.MockedXMLHttpRequest.prototype.send.calls.argsFor(0)[0]);
      expect(req['/test']).toEqual(-1)
      expect(req['__seq']).not.toBeUndefined();
      done()
    });
  });

  it("calls callbacks", function(done){
    spyOn(this.MockedXMLHttpRequest.prototype, 'open').and.callThrough();
    this.responseChunks = [
      {channel: '/test', data: {password: 'MessagebusRocks!'}}
    ];
    var spec = this;
    MessageBus.subscribe('/test', function(message){
      expect(spec.MockedXMLHttpRequest.prototype.open)
        .toHaveBeenCalledWith('POST', jasmine.stringMatching(/message-bus\/\w{32}\/poll/) );
      expect(message.password).toEqual('MessagebusRocks!');
      done();
    });
  });



});
