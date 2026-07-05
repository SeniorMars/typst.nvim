local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local browser = require("typst.preview.native.browser")
local server = require("typst.preview.native.server")
local session = require("typst.preview.native.session")
local source_maps = require("typst.preview.source_maps")
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

local function connect_and_close(host, port)
    local client = assert(uv.new_tcp(), "failed to create EOF test client")
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
local remote_ok, remote_err = pcall(server.start, {
    host = "0.0.0.0",
    port = 0,
    allow_remote = false,
})
assert(
    not remote_ok
        and tostring(remote_err):find("preview.browser.allow_remote", 1, true),
    "native preview server should refuse non-loopback hosts without opt-in"
)
assert(
    not server.is_running(),
    "refused remote preview bind should not leave the server running"
)

local remote_server = server.start({
    host = "0.0.0.0",
    port = 0,
    allow_remote = true,
})
assert(
    remote_server and server.is_running(),
    "explicit remote preview opt-in should start the native server"
)
assert(
    type(session.remote_token({ token = "auto" }, remote_server.host))
        == "string",
    "remote preview routes should receive an automatic token"
)
assert(
    session.remote_token({ token = "fixed-token" }, remote_server.host)
        == "fixed-token",
    "remote preview routes should honor a configured token"
)
server.stop()

local safe_server = server.start(config.get().preview.browser)
assert(
    safe_server and server.is_running(),
    "loopback preview server should start before invalid reconfiguration"
)
remote_ok, remote_err = pcall(server.start, {
    host = "0.0.0.0",
    port = 0,
    allow_remote = false,
})
assert(
    not remote_ok
        and tostring(remote_err):find("preview.browser.allow_remote", 1, true),
    "native preview server should refuse non-loopback reconfiguration without opt-in"
)
assert(
    server.is_running(),
    "refused remote preview reconfiguration should keep the existing server running"
)

local original_new_tcp = uv.new_tcp
local fake_closed = false
uv.new_tcp = function()
    return {
        bind = function()
            return nil, "synthetic bind failure"
        end,
        close = function()
            fake_closed = true
        end,
    }
end
local bind_ok, bind_err = pcall(server.start, {
    host = "127.0.0.1",
    port = safe_server.port + 1,
})
uv.new_tcp = original_new_tcp
assert(
    not bind_ok
        and tostring(bind_err):find("failed to bind preview server", 1, true),
    "accepted preview reconfiguration should report bind failures"
)
assert(fake_closed, "failed replacement preview handle should be closed")
assert(
    server.is_running(),
    "failed accepted preview reconfiguration should keep the existing server running"
)

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
assert(
    preview_server.port == safe_server.port,
    "accepted loopback configuration should reuse the existing safe server"
)
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

local write_callbacks = {}
local fake_client = {
    closed = false,
    writes = {},
}
function fake_client:is_closing()
    return self.closed
end
function fake_client:write(data, callback)
    self.writes[#self.writes + 1] = data
    write_callbacks[#write_callbacks + 1] = callback
end
function fake_client:shutdown(callback)
    if callback then
        callback()
    end
end
function fake_client:close()
    self.closed = true
end
local failure_fd = assert(uv.fs_open(streamed_output, "r", 438))
local failure_stat = assert(uv.fs_fstat(failure_fd))
server._send_file_for_tests(
    fake_client,
    streamed_output,
    failure_fd,
    failure_stat
)
assert(
    #fake_client.writes == 1 and #write_callbacks == 1,
    "native preview send_file test should start by writing response headers"
)
write_callbacks[1]("synthetic write failure")
assert(
    fake_client.closed == true,
    "native preview write failures after response start should close the socket"
)

local chunk_write_callbacks = {}
local chunk_failure_client = {
    closed = false,
    writes = 0,
}
function chunk_failure_client:is_closing()
    return self.closed
end
function chunk_failure_client:write(_data, callback)
    self.writes = self.writes + 1
    if self.writes > 1 then
        error("synthetic chunk write failure")
    end
    chunk_write_callbacks[#chunk_write_callbacks + 1] = callback
end
function chunk_failure_client:shutdown(callback)
    if callback then
        callback()
    end
end
function chunk_failure_client:close()
    self.closed = true
end
local chunk_failure_fd = assert(uv.fs_open(streamed_output, "r", 438))
local chunk_failure_stat = assert(uv.fs_fstat(chunk_failure_fd))
server._send_file_for_tests(
    chunk_failure_client,
    streamed_output,
    chunk_failure_fd,
    chunk_failure_stat
)
assert(
    #chunk_write_callbacks == 1,
    "chunk write failure test should capture the response header callback"
)
chunk_write_callbacks[1]()
assert(
    chunk_failure_client.closed == true,
    "native preview synchronous chunk write failures should close the socket"
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

local source_sync_fast_event = nil
config.unsafe_get().preview.source_maps.provider = {
    name = "fast-event-test",
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
    "browser source-sync route should return a successful response"
)
assert(
    source_sync_fast_event == false,
    "browser source-sync provider should run from scheduled context"
)

local original_browser_inverse = source_maps.browser_inverse
rawset(source_maps, "browser_inverse", function()
    error("synthetic source-sync route failure")
end)
local route_error_ok, route_error_response = pcall(
    http_raw,
    host,
    port,
    ("GET %ssource-sync?page=1&x=1&y=1 HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        base_path,
        host
    )
)
source_maps.browser_inverse = original_browser_inverse
assert(route_error_ok, route_error_response)
assert(
    route_error_response:find("HTTP/1.1 500 Internal Server Error", 1, true)
        and route_error_response:find("route_failed", 1, true),
    "browser source-sync route failures should return structured 500 responses"
)

local protected_route = session.set_route(project, {
    host = preview_server.host,
    port = preview_server.port,
    output = output,
    token = "secret-token",
})
assert(
    session.route_url(protected_route):find("token=secret-token", 1, true),
    "token-protected browser preview route URLs should include the token"
)
local denied_response = http_raw(
    host,
    port,
    ("GET /preview/%s/state HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        protected_route.id,
        host
    )
)
assert(
    denied_response:find("HTTP/1.1 403 Forbidden", 1, true)
        and denied_response:find("invalid_preview_token", 1, true),
    "token-protected browser preview routes should reject missing tokens"
)
local wrong_state_response = http_raw(
    host,
    port,
    ("GET /preview/%s/state?token=wrong HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        protected_route.id,
        host
    )
)
assert(
    wrong_state_response:find("HTTP/1.1 403 Forbidden", 1, true)
        and wrong_state_response:find("invalid_preview_token", 1, true),
    "token-protected browser preview state should reject wrong tokens"
)
local protected_state_response = http_raw(
    host,
    port,
    ("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        session.resource_path(protected_route, "state"),
        host
    )
)
assert(
    protected_state_response:find("HTTP/1.1 200 OK", 1, true)
        and protected_state_response:find("token_required", 1, true),
    "token-protected browser preview routes should accept matching tokens"
)
local denied_artifact_response = http_raw(
    host,
    port,
    ("GET /preview/%s/artifact HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        protected_route.id,
        host
    )
)
assert(
    denied_artifact_response:find("HTTP/1.1 403 Forbidden", 1, true)
        and denied_artifact_response:find("invalid_preview_token", 1, true),
    "token-protected browser preview artifacts should reject missing tokens"
)
local protected_artifact_response = http_raw(
    host,
    port,
    ("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        session.resource_path(protected_route, "artifact"),
        host
    )
)
assert(
    protected_artifact_response:find("HTTP/1.1 200 OK", 1, true),
    "token-protected browser preview artifacts should accept matching tokens"
)
local denied_source_sync_response = http_raw(
    host,
    port,
    ("GET /preview/%s/source-sync HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        protected_route.id,
        host
    )
)
assert(
    denied_source_sync_response:find("HTTP/1.1 403 Forbidden", 1, true)
        and denied_source_sync_response:find("invalid_preview_token", 1, true),
    "token-protected browser preview source sync should reject missing tokens"
)
local wrong_source_sync_response = http_raw(
    host,
    port,
    ("GET /preview/%s/source-sync?token=wrong HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
        protected_route.id,
        host
    )
)
assert(
    wrong_source_sync_response:find("HTTP/1.1 403 Forbidden", 1, true)
        and wrong_source_sync_response:find("invalid_preview_token", 1, true),
    "token-protected browser preview source sync should reject wrong tokens"
)
session.set_route(project, {
    host = preview_server.host,
    port = preview_server.port,
    output = output,
})
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
