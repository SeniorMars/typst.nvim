local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")
local native_server = require("typst.preview.native.server")

local state_path = assert(
    vim.env.TYPST_NVIM_PLAYWRIGHT_STATE,
    "TYPST_NVIM_PLAYWRIGHT_STATE is required"
)
local done_path = assert(
    vim.env.TYPST_NVIM_PLAYWRIGHT_DONE,
    "TYPST_NVIM_PLAYWRIGHT_DONE is required"
)

local function write_state(payload)
    vim.fn.mkdir(vim.fn.fnamemodify(state_path, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(payload) }, state_path)
end

local function finish_with_error(reason, message, fields)
    write_state(vim.tbl_extend("force", {
        ok = false,
        reason = reason,
        message = message,
    }, fields or {}))
    vim.cmd("qa!")
end

local opened_url = nil
local source_sync_request = nil

typst.reset({ force = true })
typst.providers.register("source_map", "playwright-source-map", {
    name = "playwright-source-map",
    browser_inverse = function(_, request)
        source_sync_request = request
        return {
            ok = true,
            path = root .. "/tests/fixtures/basic/main.typ",
            line = 2,
            column = 1,
            source_sync = "browser-inverse",
        }
    end,
})
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-integration.py"
    ),
    output_dir = typst_test_cache_path("playwright-preview-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        source_maps = {
            provider = "playwright-source-map",
        },
        browser = {
            server = true,
            host = "127.0.0.1",
            output_dir = typst_test_cache_path("playwright-preview-shell"),
            refresh_ms = 25,
            style = {
                variables = {
                    ["toolbar-bg"] = "#1b2430",
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
local snapshot = typst.project.set_main(main)

local compile_done = false
local compile_result = nil
typst.compiler.compile({ notify = false }, function(result)
    compile_result = result
    compile_done = true
end)
if not vim.wait(10000, function()
    return compile_done
end, 20) then
    finish_with_error("compile_timeout", "Timed out compiling preview fixture")
end

if not compile_result or compile_result.code ~= 0 then
    finish_with_error("compile_failed", "Failed to compile preview fixture", {
        result = compile_result,
    })
end

local preview_result = typst.viewer.preview({
    mode = "document",
    notify = false,
})
if
    type(preview_result) ~= "table"
    or preview_result.ok == false
    or type(opened_url) ~= "string"
then
    finish_with_error("preview_open_failed", "Failed to open native preview", {
        result = preview_result,
        opened_url = opened_url,
    })
end

local project = assert(require("typst.project.store").get(snapshot.key))
local preview_state = typst_test_preview(project)
write_state({
    ok = true,
    url = opened_url,
    output = preview_result.output or preview_state.active_output,
    transport = preview_state.active_transport,
    project = project.key,
})
vim.wait(60000, function()
    return vim.fn.filereadable(done_path) == 1
end, 50)

local sync_seen = source_sync_request ~= nil
pcall(typst.viewer.preview_stop, { notify = false })
pcall(native_server.reset)

if vim.fn.filereadable(done_path) ~= 1 then
    write_state({
        ok = false,
        reason = "playwright_timeout",
        message = "Playwright smoke did not signal completion before timeout",
        url = opened_url,
        source_sync_seen = sync_seen,
    })
end

vim.cmd("qa!")
