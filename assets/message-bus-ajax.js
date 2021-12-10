// A bare-bones implementation of $.ajax that MessageBus will use
// as a fallback if jQuery is not present
//
// Only implements methods & options used by MessageBus
(function(global) {
  'use strict';
  if (!global.MessageBus){
      throw new Error("MessageBus must be loaded before the ajax adapter");
  }

  global.MessageBus.ajax = function(options){
    var XHRImpl = (global.MessageBus && global.MessageBus.xhrImplementation) || global.XMLHttpRequest;
    var xhr = new XHRImpl();
    xhr.dataType = options.dataType;
    xhr.open('POST', options.url);
    for (var name in options.headers){
      xhr.setRequestHeader(name, options.headers[name]);
    }
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
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
    xhr.send(new URLSearchParams(options.data).toString());
    return xhr;
  };

})(window);
