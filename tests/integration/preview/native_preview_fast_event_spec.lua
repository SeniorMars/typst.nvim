local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local server = require("typst.preview.native.server")
local session = require("typst.preview.native.session")
local typst = require("typst")

local uv = vim.uv or vim.loop

local function http_raw(host, port, request)
    local client = assert(uv.new_tcp(), "failed to create preview test client")
    local chunks = {}
    local done = false
    local failure = nil

    client:connect(host, assert(tonumber(port)), function(err)
        if err then
            failure = err
            done = true
            if not client:is_closing() then
                client:close()
            end
            return
        end
        client:read_start(function(read_err, chunk)
            if read_err then
                failure = read_err
                done = true
                if not client:is_closing() then
                    client:close()
                end
                return
            end
            if chunk then
                chunks[#chunks + 1] = chunk
                return
            end
            done = true
            if not client:is_closing() then
                client:close()
            end
        end)
        client:write(request)
    end)
    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        "timed out waiting for native preview server response"
    )
    assert(
        not failure,
        "native preview server request failed: " .. tostring(failure)
    )
    return table.concat(chunks)
end

typst.reset({ force = true })
typst.setup({
    root = root,
    preview = {
        browser = {
            server = true,
            host = "127.0.0.1",
            port = 0,
        },
    },
})
local source_sync_fast_event = nil
config.unsafe_get().preview.source_maps.provider = {
    name = "fast-event-stability-test",
    browser_inverse = function(_, request)
        source_sync_fast_event = vim.in_fast_event and vim.in_fast_event()
            or false
        return {
            path = request.main,
            line = 1,
            column = 1,
        }
    end,
}

local output_dir = typst_test_cache_path("native-preview-fast-event")
vim.fn.mkdir(output_dir, "p")
local output = output_dir .. "/main.svg"
vim.fn.writefile({ "<svg></svg>" }, output)

local project = {
    key = "native-preview-fast-event",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
}
local preview_server = server.start(config.get().preview.browser)
local route = session.set_route(project, {
    host = preview_server.host,
    port = preview_server.port,
    output = output,
})
local url = session.route_url(route)
local host, port, base_path = url:match("^http://([^:/]+):(%d+)(/.*)$")
assert(host and port and base_path, "expected native preview server URL")

local source_sync_response = http_raw(
    host,
    port,
    ("GET %ssource-sync?page=1&x=1&y=1 HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
assert(
    source_sync_response:find("HTTP/1.1 200 OK", 1, true),
    "browser source-sync should return a successful response"
)
assert(
    source_sync_fast_event == false,
    "browser source-sync provider should run outside libuv fast-event context"
)

local unknown_response = http_raw(
    host,
    port,
    ("GET /not-preview HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        host
    )
)
assert(
    unknown_response:find("HTTP/1.1 404 Not Found", 1, true),
    "unknown native preview routes should return 404"
)

session.clear_route(project)
local stopped_response = http_raw(
    host,
    port,
    ("GET %sstate HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
assert(
    stopped_response:find("HTTP/1.1 410 Gone", 1, true),
    "stopped native preview routes should return 410"
)

assert(server.reset() == true, "native preview server reset should stop it")
assert(not server.is_running(), "native preview server should stop after reset")
assert(session.route_count() == 0, "native preview reset should clear routes")

vim.cmd("qa!")
