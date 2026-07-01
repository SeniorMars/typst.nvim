local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local browser = require("typst.preview.native.browser")
local server = require("typst.preview.native.server")
local session = require("typst.preview.native.session")
local typst = require("typst")

local uv = vim.uv or vim.loop

local function http_raw(host, port, request)
    local client = assert(uv.new_tcp(), "failed to create preview test client")
    local chunks = {}
    local done = false
    local failure = nil

    client:connect(host, tonumber(port), function(err)
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

local function connect_and_close(host, port)
    local client = assert(uv.new_tcp(), "failed to create EOF test client")
    local done = false
    local failure = nil

    client:connect(host, tonumber(port), function(err)
        if err then
            failure = err
            done = true
            if not client:is_closing() then
                client:close()
            end
            return
        end
        client:shutdown(function()
            done = true
            if not client:is_closing() then
                client:close()
            end
        end)
    end)

    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        "timed out waiting for EOF preview test client"
    )
    assert(not failure, "EOF preview test client failed: " .. tostring(failure))
end

typst.reset({ force = true })
typst.setup({
    root = root,
    preview = {
        browser = {
            server = true,
            host = "127.0.0.1",
            port = 0,
            max_artifact_bytes = 4,
        },
    },
})

local output_dir = typst_test_cache_path("native-server-limits")
vim.fn.mkdir(output_dir, "p")
local output = output_dir .. "/large.pdf"
vim.fn.writefile({ "0123456789" }, output, "b")

local project = {
    key = "native-server-limits",
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

local artifact_response = http_raw(
    host,
    port,
    ("GET %sartifact HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
assert(
    artifact_response:find("HTTP/1.1 413 Payload Too Large", 1, true),
    "oversized browser preview artifacts should return 413"
)
assert(
    artifact_response:find("too_large", 1, true),
    "oversized artifact response should explain the limit"
)

local streamed_output = output_dir .. "/streamed.svg"
vim.fn.writefile({
    string.rep("x", server._stream_chunk_bytes() + 17),
}, streamed_output, "b")
local streamed_stat = assert(uv.fs_stat(streamed_output))
config.unsafe_get().preview.browser.max_artifact_bytes = server._stream_chunk_bytes()
    * 2
session.set_route(project, {
    host = preview_server.host,
    port = preview_server.port,
    output = streamed_output,
})
local streamed_response = http_raw(
    host,
    port,
    ("GET %sartifact HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
assert(
    streamed_response:find("HTTP/1.1 200 OK", 1, true),
    "browser preview artifacts under the cap should return 200"
)
assert(
    streamed_response:find(
        "Content-Length: " .. tostring(streamed_stat.size),
        1,
        true
    ),
    "streamed browser preview artifacts should preserve Content-Length"
)
local streamed_body = streamed_response:match("\r\n\r\n(.*)$")
assert(
    streamed_body and #streamed_body == streamed_stat.size,
    "streamed browser preview artifact body should be complete"
)

local huge_header_response = http_raw(
    host,
    port,
    ("GET %sstate HTTP/1.1\r\nHost: %s\r\nX-Fill: %s\r\n\r\n"):format(
        base_path,
        host,
        string.rep("x", 70 * 1024)
    )
)
assert(
    huge_header_response:find("HTTP/1.1 413 Payload Too Large", 1, true),
    "oversized browser preview request headers should return 413"
)
assert(
    huge_header_response:find("header_too_large", 1, true),
    "oversized header response should report header_too_large"
)

assert(server.is_running(), "native preview server should be running")

connect_and_close(host, port)
assert(
    server.is_running(),
    "native preview server should keep running after an EOF client"
)
local state_response = http_raw(
    host,
    port,
    ("GET %sstate HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
assert(
    state_response:find("HTTP/1.1 200 OK", 1, true),
    "native preview server should handle requests after an EOF client"
)

local second_project = {
    key = "native-server-limits-second",
    root = root,
    main = root .. "/tests/fixtures/basic/chapter.typ",
}
session.set_route(second_project, {
    host = preview_server.host,
    port = preview_server.port,
    output = output,
})
assert(
    session.route_count() == 2,
    "two browser preview routes should be active"
)
browser.cleanup(project)
assert(
    session.route_count() == 1 and server.is_running(),
    "native preview server should stay running while another route exists"
)
browser.cleanup(second_project)
assert(
    session.route_count() == 0 and not server.is_running(),
    "native preview server should stop after the last route is cleared"
)

local restarted_server = server.start(config.get().preview.browser)
assert(
    server.is_running(),
    "native preview server should restart after cleanup"
)
session.set_route(project, {
    host = restarted_server.host,
    port = restarted_server.port,
    output = output,
})
assert(session.route_count() == 1, "reset fixture should create a route")
assert(server.reset() == true, "native preview server reset should stop it")
assert(not server.is_running(), "native preview server should stop after reset")
assert(
    session.route_count() == 0 and session.route_for_project(project) == nil,
    "native preview server reset should clear route session state"
)

vim.cmd("qa!")
