local html = require("typst.preview.native.html")
local log = require("typst.core.log")
local session = require("typst.preview.native.session")
local source_maps = require("typst.preview.source_maps")

local uv = vim.uv or vim.loop

local M = {}

local server = nil

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

local function read_binary(path)
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        return nil, "artifact is not a file"
    end

    local fd, open_err = uv.fs_open(path, "r", 438)
    if not fd then
        return nil, open_err or "failed to open artifact"
    end

    local body, read_err = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not body then
        return nil, read_err or "failed to read artifact"
    end
    return body
end

local function send(client, status, headers, body)
    body = body or ""
    headers = headers or {}
    headers["Content-Length"] = tostring(#body)
    headers["Connection"] = "close"
    headers["Cache-Control"] = headers["Cache-Control"] or "no-store"

    local lines = { ("HTTP/1.1 %s"):format(status) }
    for name, value in pairs(headers) do
        lines[#lines + 1] = ("%s: %s"):format(name, value)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = body

    client:write(table.concat(lines, "\r\n"), function()
        if not client:is_closing() then
            pcall(client.shutdown, client, function()
                if not client:is_closing() then
                    client:close()
                end
            end)
        end
    end)
end

local function send_json(client, status, payload)
    send(client, status, {
        ["Content-Type"] = content_types.json,
    }, html.json(payload))
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
        local result = source_maps.browser_inverse(route, query_params(query))
        local status = result.ok == false and "400 Bad Request"
            or result.pending and "202 Accepted"
            or "200 OK"
        send_json(client, status, result)
        return
    end

    if leaf == "artifact" then
        local body, err = read_binary(route.output)
        if not body then
            send_json(client, "404 Not Found", {
                ok = false,
                error = err,
            })
            return
        end
        send(client, "200 OK", {
            ["Content-Type"] = mime_for(route.output),
        }, body)
        return
    end

    send_json(client, "404 Not Found", {
        ok = false,
        error = "unknown preview resource",
    })
end

local function handle_client(client)
    local chunks = {}
    client:read_start(function(err, chunk)
        if err then
            log.add("warn", "native preview client read failed", {
                error = err,
            })
            if not client:is_closing() then
                client:close()
            end
            return
        end
        if not chunk then
            return
        end

        chunks[#chunks + 1] = chunk
        local request = table.concat(chunks)
        if not request:find("\r\n\r\n", 1, true) then
            return
        end

        client:read_stop()
        local method, target = request:match("^([A-Z]+)%s+([^%s]+)")
        target = target or "/"
        local path, query = target:match("^([^?]*)%??(.*)$")
        handle_route(client, method or "GET", path or "/", query)
    end)
end

function M.start(browser)
    if server and server.handle and not server.handle:is_closing() then
        return server
    end

    local host = browser.host or "127.0.0.1"
    local port = tonumber(browser.port) or 0
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
    return server
end

return M
