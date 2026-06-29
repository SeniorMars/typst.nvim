local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

local uv = vim.uv or vim.loop

local function http_get(url, leaf)
    local host, port, base_path = url:match("^http://([^:/]+):(%d+)(/.*)$")
    assert(host and port and base_path, "expected http preview URL: " .. url)
    local path = base_path .. (leaf or "")
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
        client:write(
            ("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"):format(
                path,
                host
            )
        )
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

typst.reset()

local opened_url = nil
local source_sync_request = nil
local function test_cache_dir(name)
    return typst_test_cache_path(name)
end

typst.providers.register("source_map", "native-server-source-map", {
    name = "native-server-source-map",
    browser_inverse = function(provider_project, request)
        source_sync_request = request
        assert(
            provider_project.main:match("tests/fixtures/basic/main%.typ$"),
            "source-map provider should receive project context"
        )
        return {
            path = provider_project.main,
            line = 2,
            column = 1,
        }
    end,
})

typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-server-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        source_maps = {
            provider = "native-server-source-map",
        },
        browser = {
            server = true,
            output_dir = test_cache_dir("preview-native-server-shell"),
            refresh_ms = 25,
            style = {
                variables = {
                    ["toolbar-bg"] = "#20242a",
                },
                css = "#meta { font-variant-numeric: tabular-nums; }",
            },
            open = function(url)
                opened_url = url
                return true
            end,
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before native server preview")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before native server preview"
)

local result = typst.viewer.preview({ mode = "document" })
assert(result and result.ok == true, "native server preview should open")
assert(opened_url == result.url, "preview should open the reported URL")

if opened_url:match("^http://") then
    assert(
        typst_test_preview(project).active_transport == "server",
        "native browser preview should record server transport"
    )

    local index_response = http_get(opened_url, "")
    assert(
        index_response:find("%-%-typst%-preview%-toolbar%-bg:%s*#20242a;"),
        "server browser shell should include configured CSS variables"
    )
    assert(
        index_response:find("#meta { font%-variant%-numeric: tabular%-nums; }"),
        "server browser shell should include configured inline CSS"
    )
    assert(
        index_response:find('id="reload"', 1, true),
        "browser shell should expose reload control"
    )
    assert(
        index_response:find('id="zoomIn"', 1, true),
        "browser shell should expose zoom controls"
    )
    assert(
        index_response:find('id="page"', 1, true),
        "browser shell should expose page control"
    )
    assert(
        index_response:find('id="sync"', 1, true),
        "browser shell should expose source-sync control"
    )
    assert(
        index_response:find("metadataText", 1, true)
            and index_response:find('event.key === "r"', 1, true),
        "browser shell should expose metadata and keyboard reload handling"
    )

    local state_response = http_get(opened_url, "state")
    assert(
        state_response:find("HTTP/1.1 200 OK", 1, true),
        "state request should return 200"
    )
    assert(
        state_response:find('"ok":true', 1, true),
        "state response should report ok=true"
    )
    assert(
        state_response:find("main.pdf", 1, true),
        "state response should include the active output name"
    )
    assert(
        state_response:find('"output_format":"pdf"', 1, true),
        "state response should include output format metadata"
    )
    assert(
        state_response:find('"output_kind":"pdf"', 1, true),
        "state response should include output kind metadata"
    )
    assert(
        state_response:find('"browser_click":true', 1, true),
        "state response should advertise browser source sync"
    )

    local artifact_response = http_get(opened_url, "artifact")
    assert(
        artifact_response:find("HTTP/1.1 200 OK", 1, true),
        "artifact request should return 200"
    )
    assert(
        artifact_response:find("fake typst.nvim watch%-cycle fixture"),
        "artifact response should contain the compiled output"
    )

    local sync_response = http_get(
        opened_url,
        "source-sync?x=12&y=34&page=3&viewport_width=640&viewport_height=480&target=svg"
    )
    assert(
        sync_response:find("HTTP/1.1 200 OK", 1, true),
        "source-sync request should return 200"
    )
    assert(
        sync_response:find('"source_sync":"browser%-inverse"')
            or sync_response:find('"source_sync":"browser-inverse"', 1, true),
        "source-sync response should report browser inverse sync"
    )
    assert(
        source_sync_request,
        "source-map provider should receive click event"
    )
    assert(
        source_sync_request.page == 3
            and source_sync_request.x == 12
            and source_sync_request.y == 34,
        "source-map provider should receive normalized click coordinates"
    )
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert(cursor[1] == 2, "source-sync provider result should jump to line")
else
    assert(
        opened_url:match("^file://"),
        "native browser preview should use server URL or file-shell fallback"
    )
    assert(
        typst_test_preview(project).active_transport == "file-shell",
        "file-shell fallback should record its transport"
    )
end

assert(typst.viewer.preview_stop({ notify = false }) == true)

vim.cmd("qa!")
