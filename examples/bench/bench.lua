wrk.method = "POST"
wrk.body = ""
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"
wrk.headers["Connection"] = "keep-alive"

request = function()
  local hexdict = {48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102}
  local randstr = {}
  for i=1, 32 do
    randstr[i] = hexdict[math.random(1, 16)]
  end
  local path = wrk.path .. "message-bus/" .. string.char(unpack(randstr)) .. "/poll"
  return wrk.format(nil, path)
end
