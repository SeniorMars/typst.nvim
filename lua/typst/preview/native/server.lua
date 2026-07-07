local html = require("typst.preview.native.html")
local log = require("typst.core.log")
local session = require("typst.preview.native.session")
local source_maps = require("typst.preview.source_maps")

local uv = vim.uv or vim.loop

local M = {}

---@class TypstPreviewNativeServerState
---@field handle any
---@field host string
---@field port integer
---@field browser table?
---@field source_map boolean?
---@field source_map_provider string?
---@field source_map_path string?
---@field root string?
---@field project_id string?

---@type TypstPreviewNativeServerState?
local server = nil
local HEADER_LIMIT_BYTES = 64 * 1024
local READ_TIMEOUT_MS = 5000
local STREAM_CHUNK_BYTES = 64 * 1024
local response_started = setmetatable({}, { __mode = "k" })
local function loopback_host(host)
    return host == "127.0.0.1"
        or host == "localhost"
        or host == "::1"
        or host == "[::1]"
end

local function remote_allowed(browser, host)
    return loopback_host(host) or browser.allow_remote == true
end

local function remote_error()
    return "typst.nvim: preview.browser.host must be loopback unless preview.browser.allow_remote = true"
end

local function is_running(current)
    return current and current.handle and not current.handle:is_closing()
end

local function stop_server(current)
    if current and current.handle and not current.handle:is_closing() then
        current.handle:close()
        return true
    end
    return false
end

local content_types = {
    html = "text/html; charset=utf-8",
    json = "application/json; charset=utf-8",
    pdf = "application/pdf",
    png = "image/png",
    svg = "image/svg+xml; charset=utf-8",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
}

local function mime_for(path)
    local ext = vim.fn.fnamemodify(path or "", ":e"):lower()
    return content_types[ext] or "application/octet-stream"
end

local function browser_config()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return {}
    end
    return ((config.unsafe_get().preview or {}).browser or {})
end

local function max_artifact_bytes()
    return tonumber(browser_config().max_artifact_bytes) or (32 * 1024 * 1024)
end

local function open_artifact(path)
    local fd, open_err = uv.fs_open(path, "r", 438)
    if not fd then
        return nil, nil, open_err or "failed to open artifact"
    end

    local stat = uv.fs_fstat(fd)
    if not stat or stat.type ~= "file" then
        pcall(uv.fs_close, fd)
        return nil, nil, "artifact is not a file"
    end
    local max_bytes = max_artifact_bytes()
    if max_bytes > 0 and stat.size > max_bytes then
        pcall(uv.fs_close, fd)
        return nil,
            nil,
            ("artifact is too large for browser preview (%d bytes > %d bytes)"):format(
                stat.size,
                max_bytes
            ),
            "too_large"
    end
    return fd, stat
end

local function close_client(client)
    if client:is_closing() then
        return
    end
    local ok = pcall(client.shutdown, client, function()
        if not client:is_closing() then
            client:close()
        end
    end)
    if not ok and not client:is_closing() then
        client:close()
    end
end

local function response_head(status, headers, length)
    headers = headers or {}
    headers["Content-Length"] = tostring(length or 0)
    headers["Connection"] = "close"
    headers["Cache-Control"] = headers["Cache-Control"] or "no-store"

    local lines = { ("HTTP/1.1 %s"):format(status) }
    for name, value in pairs(headers) do
        lines[#lines + 1] = ("%s: %s"):format(name, value)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    return table.concat(lines, "\r\n")
end

local function send(client, status, headers, body)
    body = body or ""
    local ok, err = pcall(
        client.write,
        client,
        response_head(status, headers, #body) .. body,
        function()
            close_client(client)
        end
    )
    if ok then
        response_started[client] = true
        return
    end
    if not client:is_closing() then
        client:close()
    end
    error(err)
end

local function send_json(client, status, payload)
    send(client, status, {
        ["Content-Type"] = content_types.json,
    }, html.json(payload))
end

local function send_file(client, path, fd, stat)
    local offset = 0
    local function close_file()
        if fd then
            pcall(uv.fs_close, fd)
            fd = nil
        end
    end

    local function finish()
        close_file()
        close_client(client)
    end

    local function write_next(write_err)
        if write_err then
            log.add("warn", "native preview artifact write failed", {
                path = path,
                error = write_err,
            })
            finish()
            return
        end
        if client:is_closing() then
            close_file()
            return
        end
        if offset >= stat.size then
            finish()
            return
        end

        local length = math.min(STREAM_CHUNK_BYTES, stat.size - offset)
        local chunk, read_err = uv.fs_read(fd, length, offset)
        if not chunk then
            log.add("warn", "native preview artifact read failed", {
                path = path,
                error = read_err,
            })
            finish()
            return
        end
        if #chunk == 0 then
            finish()
            return
        end

        offset = offset + #chunk
        local ok, write_err = pcall(client.write, client, chunk, write_next)
        if not ok then
            log.add("warn", "native preview artifact write failed", {
                path = path,
                error = write_err,
            })
            finish()
        end
    end

    local ok, err = pcall(
        client.write,
        client,
        response_head("200 OK", {
            ["Content-Type"] = mime_for(path),
        }, stat.size),
        write_next
    )
    if ok then
        response_started[client] = true
        return
    end
    close_file()
    if not client:is_closing() then
        client:close()
    end
    error(err)
end

local function decode_component(value)
    value = tostring(value or ""):gsub("+", " ")
    return (
        value:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    )
end

local function query_params(query)
    local params = {}
    for key, value in tostring(query or ""):gmatch("([^&=?]+)=?([^&]*)") do
        params[decode_component(key)] = decode_component(value)
    end
    return params
end

local function route_authorized(route, params)
    local token = route and route.token
    if type(token) ~= "string" or token == "" then
        return true
    end
    return params and params.token == token
end

local function handle_route(client, method, path, query)
    local id, leaf = path:match("^/preview/([%w_%-]+)/?(.*)$")
    if not id then
        send_json(client, "404 Not Found", {
            ok = false,
            error = "unknown route",
        })
        return
    end

    local route = session.route_for_id(id)
    if not route then
        send_json(client, "410 Gone", {
            ok = false,
            error = "preview stopped",
        })
        return
    end

    local params = query_params(query)
    if not route_authorized(route, params) then
        send_json(client, "403 Forbidden", {
            ok = false,
            error = "preview route token is required",
            reason = "invalid_preview_token",
        })
        return
    end

    leaf = leaf == "" and "index" or leaf
    if leaf == "index" then
        send(client, "200 OK", {
            ["Content-Type"] = content_types.html,
        }, html.server_shell(route))
        return
    end

    if leaf == "state" then
        send_json(client, "200 OK", session.state_payload(route))
        return
    end

    if leaf == "source-sync" then
        if method ~= "GET" and method ~= "POST" then
            send_json(client, "405 Method Not Allowed", {
                ok = false,
                error = "unsupported method",
            })
            return
        end
        local result = source_maps.browser_inverse(route, params)
        local status = result.ok == false and "400 Bad Request"
            or result.pending and "202 Accepted"
            or "200 OK"
        send_json(client, status, result)
        return
    end

    if leaf == "artifact" then
        local fd, stat, err, reason = open_artifact(route.output)
        if not fd then
            send_json(
                client,
                reason == "too_large" and "413 Payload Too Large"
                    or "404 Not Found",
                {
                    ok = false,
                    error = err,
                    reason = reason,
                }
            )
            return
        end
        send_file(client, route.output, fd, stat)
        return
    end

    send_json(client, "404 Not Found", {
        ok = false,
        error = "unknown preview resource",
    })
end

local function handle_client(client)
    local chunks = {}
    local byte_count = 0
    local timer = uv.new_timer()
    if timer then
        timer:start(READ_TIMEOUT_MS, 0, function()
            if not client:is_closing() then
                client:read_stop()
                send_json(client, "408 Request Timeout", {
                    ok = false,
                    error = "request timed out",
                    reason = "timeout",
                })
            end
            if timer and not timer:is_closing() then
                timer:close()
            end
        end)
    end

    local function close_timer()
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        timer = nil
    end

    client:read_start(function(err, chunk)
        if err then
            close_timer()
            log.add("warn", "native preview client read failed", {
                error = err,
            })
            if not client:is_closing() then
                client:close()
            end
            return
        end
        if not chunk then
            close_timer()
            if not client:is_closing() then
                client:close()
            end
            return
        end

        chunks[#chunks + 1] = chunk
        byte_count = byte_count + #chunk
        if byte_count > HEADER_LIMIT_BYTES then
            close_timer()
            client:read_stop()
            send_json(client, "413 Payload Too Large", {
                ok = false,
                error = "request headers are too large",
                reason = "header_too_large",
                limit = HEADER_LIMIT_BYTES,
            })
            return
        end
        local request = table.concat(chunks)
        if not request:find("\r\n\r\n", 1, true) then
            return
        end

        close_timer()
        client:read_stop()
        local method, target = request:match("^([A-Z]+)%s+([^%s]+)")
        target = target or "/"
        local path, query = target:match("^([^?]*)%??(.*)$")
        method = method or "GET"
        path = path or "/"
        query = query or ""
        -- The read callback is a libuv fast-event context. Route handlers may
        -- resolve projects, invoke providers, emit events, or open buffers, so
        -- dispatch the full route on the main loop and keep socket parsing here.
        vim.schedule(function()
            if client:is_closing() then
                return
            end
            local ok, route_err = xpcall(function()
                handle_route(client, method, path, query)
            end, debug.traceback)
            if ok then
                return
            end

            log.add("warn", "native preview route failed", {
                method = method,
                path = path,
                error = route_err,
            })
            if not client:is_closing() and response_started[client] ~= true then
                local sent =
                    pcall(send_json, client, "500 Internal Server Error", {
                        ok = false,
                        error = "preview route failed",
                        reason = "route_failed",
                    })
                if not sent and not client:is_closing() then
                    client:close()
                end
            end
        end)
    end)
end

function M.start(browser)
    browser = browser or {}
    local host = browser.host or "127.0.0.1"
    local port = tonumber(browser.port) or 0

    if not remote_allowed(browser, host) then
        error(remote_error())
    end

    local current = server
    if current and is_running(current) then
        if current.host == host and (port == 0 or current.port == port) then
            return current
        end
    end

    local previous = current

    local handle, new_err = uv.new_tcp()
    if not handle then
        error(
            ("typst.nvim: failed to create preview server: %s"):format(new_err)
        )
    end

    local ok, bind_err = handle:bind(host, port)
    if not ok then
        handle:close()
        error(
            ("typst.nvim: failed to bind preview server: %s"):format(bind_err)
        )
    end

    ok, bind_err = handle:listen(64, function(err)
        if err then
            log.add("warn", "native preview server accept failed", {
                error = err,
            })
            return
        end

        local client = uv.new_tcp()
        if not client then
            return
        end
        handle:accept(client)
        handle_client(client)
    end)
    if not ok then
        handle:close()
        error(
            ("typst.nvim: failed to listen on preview server: %s"):format(
                bind_err
            )
        )
    end

    local sockname = handle:getsockname() or {}
    server = {
        handle = handle,
        host = host,
        port = sockname.port or port,
    }
    stop_server(previous)
    return server
end

function M.stop()
    local current = server
    server = nil
    return stop_server(current)
end

function M.reset()
    local stopped = M.stop()
    session.reset()
    return {
        ok = true,
        status = stopped and "reset" or "skipped",
        stopped = stopped,
        reason = stopped and nil or "not_running",
    }
end

function M.is_running()
    return server ~= nil
        and server.handle ~= nil
        and not server.handle:is_closing()
end

function M._stream_chunk_bytes()
    return STREAM_CHUNK_BYTES
end

function M._send_file_for_tests(client, path, fd, stat)
    return send_file(client, path, fd, stat)
end

return M
