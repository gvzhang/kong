local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local cjson = require "cjson"

local HgTcpLogHandler = BasePlugin:extend()

local function log(premature, conf, message)
  if premature then
    return
  end
  
  local ok, err
  local host = conf.host
  local port = conf.port
  local timeout = conf.timeout
  local keepalive = conf.keepalive

  local sock = ngx.socket.tcp()
  sock:settimeout(timeout)

  ok, err = sock:connect(host, port)
  if not ok then
    ngx.log(ngx.ERR, "[hg-tcp-log] failed to connect to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  ok, err = sock:send(cjson.encode(message) .. "\r\n")
  if not ok then
    ngx.log(ngx.ERR, "[hg-tcp-log] failed to send data to " .. host .. ":" .. tostring(port) .. ": ", err)
  end

  ok, err = sock:setkeepalive(keepalive)
  if not ok then
    ngx.log(ngx.ERR, "[hg-tcp-log] failed to keepalive to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end
end

function HgTcpLogHandler:new()
  HgTcpLogHandler.super.new(self, "hg-tcp-log")
end

function HgTcpLogHandler:body_filter(conf)
  HgTcpLogHandler.super.body_filter(self)

  local chunk = ngx.arg[1]
  local res_body = ngx.ctx.res_body or "" -- minimize the number of calls to ngx.ctx while fallbacking on default value
  ngx.ctx.res_body = res_body .. chunk
end

function HgTcpLogHandler:log(conf)
  HgTcpLogHandler.super.log(self)

  local message = basic_serializer.serialize(ngx)
  message.request.postdata = ngx.req.get_post_args()
  message.response.body = ngx.ctx.res_body
  local ok, err = ngx.timer.at(0, log, conf, message)
  if not ok then
    ngx.log(ngx.ERR, "[hg-tcp-log] failed to create timer: ", err)
  end
end

return HgTcpLogHandler
