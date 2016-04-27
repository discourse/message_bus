-- wrk returns lots of read errors, this is unavoidable cause
--
-- 1. There is no internal implmentation of chunked encoding in wrk (which would be ideal)
--
-- 2. MessageBus gem does not provide http keepalive (by design), and can not provide content length
--   if MessageBus provided keepalive it would have to be able to redispatch the reqs to rack, something
--   that is not supported by the underlying rack hijack protocol, once a req is hijacked it can not be
--   returned
--
-- This leads to certain read errors while the bench runs cause wrk can not figure out cleanly that
-- MessageBus is done with a request
--

wrk.method = "POST"
wrk.body = ""
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"

-- chunking is not supported internally to wrk
wrk.headers["Dont-Chunk"] = "true"
wrk.headers["Connection"] = "Close"

request = function()
  local hexdict = {48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102}
  local randstr = {}
  for i=1, 32 do
    randstr[i] = hexdict[math.random(1, 16)]
  end
  local path = wrk.path .. "message-bus/" .. string.char(unpack(randstr)) .. "/poll"
  return wrk.format(nil, path)
end
