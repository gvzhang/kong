
local ffi = require "ffi"
local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local cjson = require "cjson"
local redis = require "resty.redis"
local system_constants = require "lua_system_constants"
local pcall = pcall
local ngx_req_get_post_args = ngx.req.get_post_args
local json_decode = cjson.decode
local json_encode = cjson.encode
cjson.encode_empty_table_as_object(false)

local RedisLogHandler = BasePlugin:extend()

-- we need to log log_data from response before transform
RedisLogHandler.PRIORITY = 810

-- switch to the file log when the network of redis server is broken
local O_CREAT = system_constants.O_CREAT()
local O_WRONLY = system_constants.O_WRONLY()
local O_APPEND = system_constants.O_APPEND()
local S_IRUSR = system_constants.S_IRUSR()
local S_IWUSR = system_constants.S_IWUSR()
local S_IRGRP = system_constants.S_IRGRP()
local S_IROTH = system_constants.S_IROTH()

local oflags = bit.bor(O_WRONLY, O_CREAT, O_APPEND)
local mode = bit.bor(S_IRUSR, S_IWUSR, S_IRGRP, S_IROTH)

ffi.cdef[[
int open(const char * filename, int flags, int mode);
int write(int fd, const void * ptr, int numbytes);
int close(int fd);
char *strerror(int errnum);
]]

-- fd tracking utility functions
local file_descriptors = {}

local function log_to_file( conf, message )

    local msg = json_encode(message) .. "\n"

    local fd = file_descriptors[conf.path]

    if fd and conf.reopen then
        -- close fd, we do this here, to make sure a previously cached fd also
        -- gets closed upon dynamic changes of the configuration
        ffi.C.close(fd)
        file_descriptors[conf.path] = nil
        fd = nil
    end

    if not fd then
        fd = ffi.C.open(conf.path, oflags, mode)
        if fd < 0 then
            local errno = ffi.errno()
            error("[redis-file-log] failed to open the file: " .. ffi.string(ffi.C.strerror(errno)))
            return
        else
            file_descriptors[conf.path] = fd
        end
    end

    ffi.C.write(fd, msg, #msg)
end

-- log to redis server
local function log_to_redis( conf, message )

    local ok, err
    local host = conf.host
    local port = conf.port
    local database = conf.database
    local password = conf.password
    local key = conf.key
    local timeout = conf.timeout

    local red = redis:new()
    red:set_timeout(timeout)
    ok, err = red:connect(host, port)
    if not ok then
        error("[redis-log] failed to connect to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return
    end

    -- If the current connection does not come from the built-in connection pool, 
    -- then this method always returns 0, that is, the connection has never been reused (yet). 
    -- If the connection comes from the connection pool, then the return value is always non-zero.
    -- So this method can also be used to determine if the current connection comes from the pool.
    -- Only need to establish a connection when in the first certification, then just use it directly.
    local count
    count, err = red:get_reused_times()
    if 0 == count then
        if password and password ~= "" then
            ok, err = red:auth(password)
            if not ok then
                error("[redis-log] failed to connect to " .. host .. ":" .. tostring(port) .. ": " .. err)
                return
            end
        end
    elseif err then
        error("[redis-log] failed to connect to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return
    end

    if database ~= nil and database > 0 then
        ok, err = red:select(database)
        if not ok then
            error("[redis-log] failed to change Redis database from " .. host .. ":" .. tostring(port) .. ": " .. err)
            return
        end
    end

    ok, err = red:rpush(key, json_encode(message) .. "\r\n")
    if not ok then
        error("[redis-log] failed to send data to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return
    end

    -- pool size is 100, and the maximum idle time is set to 10 seconds
    ok, err = red:set_keepalive(10000, 100)
    if not ok then
        error("[redis-log] failed to keepalive to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return
    end
end

--  error switch
local is_redis_error = false

local function check_redis()
    is_redis_error = false
end

-- Log to redis or log to a file when redis server is broken. 
-- Function used as callback from an nginx timer.
-- @param `premature` see OpenResty `ngx.timer.at()`
-- the premature argument takes a boolean value indicating whether it is a premature timer expiration or not
-- @param `conf`     Configuration table, holds http endpoint details
-- @param `message`  Message to be logged
local function log(premature, conf, message)
    if is_redis_error then
        -- change to file log
        local ok, error_msg = pcall(log_to_file, conf, message)
        if not ok then
            ngx.log(ngx.ERR, error_msg)
        end
        return
    end

    local ok, error_msg = pcall(log_to_redis, conf, message)
    if not ok then
        is_redis_error = true
        ngx.log(ngx.ERR, error_msg)

        -- change to file log
        local ok, error_msg = pcall(log_to_file, conf, message)
        if not ok then
            ngx.log(ngx.ERR, error_msg)
        end

        -- regular check redis
        local ok, err = ngx.timer.at(conf.broken_timeout, check_redis)
        if not ok then
            ngx.log(ngx.ERR, "[redis-log] failed to create check_redis timer: ", err)
        end
    end
end

function RedisLogHandler:new()
    RedisLogHandler.super.new(self, "redis-log")
end

-- save the share variable ngx.ctx.resp_body before transform
function RedisLogHandler:body_filter(conf)
    RedisLogHandler.super.body_filter(self)

    local chunk = ngx.arg[1]
    -- minimize the number of calls to ngx.ctx while fallbacking on default value
    local resp_body = ngx.ctx.resp_body or ""
    ngx.ctx.resp_body = resp_body .. chunk
end

function RedisLogHandler:log(conf)
    RedisLogHandler.super.log(self)

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
    local content_type = message.response.headers["Content-Type"]
    if content_type ~= nil and string.lower(content_type) == "application/json" and ngx.ctx.resp_body ~= nil then
        -- solve the chinese problem, because the data is serialized
        local ok, ret = pcall(json_decode, ngx.ctx.resp_body)
        if ok then
           message.response.body = json_encode(ret)
        end
    end

    local ok, err = ngx.timer.at(0, log, conf, message)
    if not ok then
        ngx.log(ngx.ERR, "[redis-log] failed to create timer: ", err)
    end
end

return RedisLogHandler
