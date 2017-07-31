local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local cjson = require "cjson"
local pcall = pcall
local ngx_req_get_post_args = ngx.req.get_post_args
cjson.encode_empty_table_as_object(false)

local HgTcpLogHandler = BasePlugin:extend()

-- we need to log log_data from response before transform
HgTcpLogHandler.PRIORITY = 810

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
    -- minimize the number of calls to ngx.ctx while fallbacking on default value
    local res_body = ngx.ctx.res_body or ""
    ngx.ctx.res_body = res_body .. chunk
end

function HgTcpLogHandler:log(conf)
    HgTcpLogHandler.super.log(self)

    local message = basic_serializer.serialize(ngx)
    -- The pcall function calls its first argument in protected mode,
    -- so that it catches any errors while the function is running.
    -- If there are no errors, pcall returns true, plus any values returned by the call.
    -- Otherwise, it returns false, plus the error message.
    local ok, res = pcall(ngx_req_get_post_args)
    if ok then
        message.request.postdata = res
    end
    if ngx.ctx.res_body then
        message.response.body = cjson.decode(ngx.ctx.res_body)
        -- solve the chinese problem
        message.response.body = cjson.encode(message.response.body)
    end
    local ok, err = ngx.timer.at(0, log, conf, message)
    if not ok then
        ngx.log(ngx.ERR, "[hg-tcp-log] failed to create timer: ", err)
    end
end

return HgTcpLogHandler
