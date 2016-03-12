// A bare-bones implementation of $.ajax that MessageBus will use
// as a fallback if jQuery is not present
//
// Only implements methods & options used by MessageBus
(function(global, undefined) {
  'use strict';
  var cacheBuster =  Math.random() * 10000 | 0;
  var MessageBus = global.MessageBus || (global.MessageBus = {});

  MessageBus.ajaxImplementation = function(options){
    var XHRImpl = MessageBus.xhrImplementation || global.XMLHttpRequest;
    var xhr = new XHRImpl();
    xhr.dataType = options.dataType;
    var url = options.url;
    if (!options.cache){
      url += ((-1 == url.indexOf('?')) ? '?' : '&') + '_=' + (cacheBuster++)
    }
    xhr.open('POST', url);
    for (var name in options.headers){
      xhr.setRequestHeader(name, options.headers[name]);
    }
    if (options.messageBus.chunked){
      options.messageBus.onProgressListener(xhr);
    }
    xhr.onreadystatechange = function(){
      if (xhr.readyState === 4){
        var status = xhr.status;
        if (status >= 200 && status < 300 || status === 304){
          options.success(xhr.responseText);
        } else {
          options.error(xhr, xhr.statusText);
        }
        options.complete();
      }
    }
    xhr.send(options.data);
    return xhr;
  };

})(window);
