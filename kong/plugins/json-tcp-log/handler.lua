local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local cjson = require "cjson"
local pcall = pcall
local ngx_req_get_post_args = ngx.req.get_post_args
local json_decode = cjson.decode
local json_encode = cjson.encode
cjson.encode_empty_table_as_object(false)

local JsonTcpLogHandler = BasePlugin:extend()

-- we need to log log_data from response before transform
JsonTcpLogHandler.PRIORITY = 810

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
        ngx.log(ngx.ERR, "[json-tcp-log] failed to connect to " .. host .. ":" .. tostring(port) .. ": ", err)
        return
    end

    ok, err = sock:send(cjson.encode(message) .. "\r\n")
    if not ok then
        ngx.log(ngx.ERR, "[json-tcp-log] failed to send data to " .. host .. ":" .. tostring(port) .. ": ", err)
    end

    ok, err = sock:setkeepalive(keepalive)
    if not ok then
        ngx.log(ngx.ERR, "[json-tcp-log] failed to keepalive to " .. host .. ":" .. tostring(port) .. ": ", err)
        return
    end
end

function JsonTcpLogHandler:new()
    JsonTcpLogHandler.super.new(self, "json-tcp-log")
end

-- save the share variable ngx.ctx.resp_body before transform
function JsonTcpLogHandler:body_filter(conf)
    JsonTcpLogHandler.super.body_filter(self)

    local chunk = ngx.arg[1]
    -- minimize the number of calls to ngx.ctx while fallbacking on default value
    local resp_body = ngx.ctx.resp_body or ""
    ngx.ctx.resp_body = resp_body .. chunk
end

function JsonTcpLogHandler:log(conf)
    JsonTcpLogHandler.super.log(self)

    local message = basic_serializer.serialize(ngx)
    -- The pcall function calls its first argument in protected mode,
    -- so that it catches any errors while the function is running.
    -- If there are no errors, pcall returns true, plus any values returned by the call.
    -- Otherwise, it returns false, plus the error message.
    local ok, res = pcall(ngx_req_get_post_args)
    if ok then
        message.request.postdata = res
    end

    -- log JSON date
    local content_type = message.response.headers["Content-Type"];
    if content_type ~= nil and string.lower(content_type) == "application/json" and ngx.ctx.resp_body ~= nil then
        -- solve the chinese problem, because the data is serialized
        local ok, ret = pcall(json_decode, ngx.ctx.resp_body)
        if ok then
           message.response.body = json_encode(ret)
        end
    end
    
    local ok, err = ngx.timer.at(0, log, conf, message)
    if not ok then
        ngx.log(ngx.ERR, "[json-tcp-log] failed to create timer: ", err)
    end
end

return JsonTcpLogHandler
