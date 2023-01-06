/* eslint-env es2022 */
/* global describe, it, spyOn, MessageBus, expect, jasmine, testMB */

function approxEqual(valueOne, valueTwo) {
  return Math.abs(valueOne - valueTwo) < 500;
}

describe("Messagebus", function () {
  it("submits change requests", function(done){
    spyOn(this.MockedXMLHttpRequest.prototype, 'send').and.callThrough();
    var spec = this;
    MessageBus.subscribe('/test', function(){
      expect(spec.MockedXMLHttpRequest.prototype.send)
        .toHaveBeenCalled()
      var data = spec.MockedXMLHttpRequest.prototype.send.calls.argsFor(0)[0];
      var params = new URLSearchParams(data);
      expect(params.get("/test")).toEqual("-1");
      expect(params.get("__seq")).toMatch(/\d+/);
      done();
    });
  });

  it("calls callbacks", function(done){
    MessageBus.subscribe('/test', function(message){
      expect(message.password).toEqual('MessageBusRocks!');
      done();
    });
  });

  it('returns status', function(done){
    MessageBus.pause();
    expect(MessageBus.status()).toMatch("paused");
    MessageBus.resume();
    expect(MessageBus.status()).toMatch("started");
    MessageBus.stop();
    expect(MessageBus.status()).toMatch("stopped");
    done();
  });

  it('stores messages when paused, then delivers them when resumed', function(done){
    MessageBus.pause()
    spyOn(this.MockedXMLHttpRequest.prototype, 'send').and.callThrough();
    var spec = this;
    var onMessageSpy = jasmine.createSpy('onMessageSpy');
    MessageBus.subscribe('/test', onMessageSpy);
    setTimeout(function(){
      expect(spec.MockedXMLHttpRequest.prototype.send).toHaveBeenCalled()
      expect(onMessageSpy).not.toHaveBeenCalled()
      MessageBus.resume()
    }, 1010) // greater than delayPollTimeout of 500 + 500 random
    setTimeout(function(){
      expect(onMessageSpy).toHaveBeenCalled()
      done()
    }, 1050) // greater than first timeout above
  });

  it('can unsubscribe from callbacks', function(done){
    var onMessageSpy = jasmine.createSpy('onMessageSpy');
    MessageBus.subscribe('/test', onMessageSpy);
    MessageBus.unsubscribe('/test', onMessageSpy);
    MessageBus.subscribe('/test', function(){
      expect(onMessageSpy).not.toHaveBeenCalled()
      done()
    });
  });

  testMB('sets dlp parameter when longPolling is disabled', function(){
    MessageBus.enableLongPolling = false
    this.perform(function(message, xhr){
      expect(xhr.url).toMatch("dlp=t");
    }).finally(function(){
      MessageBus.enableLongPolling = true
    })
  });

  testMB('respects baseUrl setting', function(){
    MessageBus.baseUrl = "/a/test/base/url/";
    this.perform(function(message, xhr){
      expect(xhr.url).toMatch("/a/test/base/url/");
    }).finally(function(){
      MessageBus.baseUrl = "/";
    })
  });

  it('respects minPollInterval setting with defaults', function(){
    expect(MessageBus.minPollInterval).toEqual(100);
    MessageBus.minPollInterval = 1000;
    expect(MessageBus.minPollInterval).toEqual(1000);
  });

  testMB('sends using custom header', function(){
    MessageBus.headers['X-MB-TEST-VALUE'] = '42';
    this.perform(function(message, xhr){
      expect(xhr.headers).toEqual({
        'X-SILENCE-LOGGER': 'true',
        'X-MB-TEST-VALUE': '42',
        'Content-Type': 'application/x-www-form-urlencoded'
      });
    }).finally(function(){
      MessageBus.headers = {};
    })
  });

  it("respects Retry-After response header when larger than 15 seconds", async function () {
    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(window, "setTimeout").and.callThrough();

    this.responseStatus = 429;
    this.responseHeaders["Retry-After"] = "23";

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));

    const nextPollScheduledIn = window.setTimeout.calls.mostRecent().args[1];
    expect(nextPollScheduledIn).toEqual(23000);
  });

  it("retries after 15s for lower retry-after values", async function () {
    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(window, "setTimeout").and.callThrough();

    this.responseStatus = 429;
    this.responseHeaders["Retry-After"] = "13";

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));

    const nextPollScheduledIn = window.setTimeout.calls.mostRecent().args[1];
    expect(nextPollScheduledIn).toEqual(15000);
  });

  it("waits for callbackInterval after receiving data in chunked long-poll mode", async function () {
    // The callbackInterval is equal to the length of the server response in chunked long-poll mode, so
    // this ultimately ends up being a continuous stream of requests

    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(window, "setTimeout").and.callThrough();

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));

    const nextPollScheduledIn = window.setTimeout.calls.mostRecent().args[1];
    expect(
      approxEqual(nextPollScheduledIn, MessageBus.callbackInterval)
    ).toEqual(true);
  });

  it("waits for backgroundCallbackInterval after receiving data in non-long-poll mode", async function () {
    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(window, "setTimeout").and.callThrough();
    MessageBus.shouldLongPollCallback = () => false;
    MessageBus.enableChunkedEncoding = false;

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));

    const nextPollScheduledIn = window.setTimeout.calls.mostRecent().args[1];
    expect(
      approxEqual(nextPollScheduledIn, MessageBus.backgroundCallbackInterval)
    ).toEqual(true);
  });

  it("re-polls immediately after receiving data in non-chunked long-poll mode", async function () {
    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(window, "setTimeout").and.callThrough();
    MessageBus.enableChunkedEncoding = false;

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));

    const nextPollScheduledIn = window.setTimeout.calls.mostRecent().args[1];
    expect(nextPollScheduledIn).toEqual(MessageBus.minPollInterval);
  });

  it("enters don't-chunk-mode if first chunk times out", async function () {
    spyOn(this.MockedXMLHttpRequest.prototype, "send").and.callThrough();
    spyOn(
      this.MockedXMLHttpRequest.prototype,
      "setRequestHeader"
    ).and.callThrough();

    let resolveFirstResponse;
    this.delayResponsePromise = new Promise(
      (resolve) => (resolveFirstResponse = resolve)
    );
    MessageBus.firstChunkTimeout = 50;

    await new Promise((resolve) => MessageBus.subscribe("/test", resolve));
    resolveFirstResponse();

    const calls =
      this.MockedXMLHttpRequest.prototype.setRequestHeader.calls.all();

    const dontChunkCalls = calls.filter((c) => c.args[0] === "Dont-Chunk");
    expect(dontChunkCalls.length).toEqual(1);
  });

  it("doesn't enter don't-chunk-mode if aborted before first chunk", async function () {
    spyOn(
      this.MockedXMLHttpRequest.prototype,
      "setRequestHeader"
    ).and.callThrough();

    this.delayResponsePromise = new Promise(() => {});
    MessageBus.firstChunkTimeout = 300;

    const requestWasStarted = new Promise(
      (resolve) => (this.requestStarted = resolve)
    );

    // Trigger request
    const subscribedPromise = new Promise((resolve) =>
      MessageBus.subscribe("/test", resolve)
    );

    await requestWasStarted;

    // Change subscription (triggers an abort and re-poll)
    MessageBus.subscribe("/test2", () => {});

    // Wait for stuff to settle
    await subscribedPromise;

    // Wait 300ms to ensure dontChunk timeout has passed
    await new Promise((resolve) => setTimeout(resolve, 300));

    const calls =
      this.MockedXMLHttpRequest.prototype.setRequestHeader.calls.all();

    const dontChunkCalls = calls.filter((c) => c.args[0] === "Dont-Chunk");
    expect(dontChunkCalls.length).toEqual(0);
  });
});
