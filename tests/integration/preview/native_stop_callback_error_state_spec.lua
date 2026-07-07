local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local controller = require("typst.preview.controller")
local native = require("typst.preview.native")
local preview_service = require("typst.project.services.preview")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

cleanup()

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("native-stop-callback-error-output"),
    preview = {
        provider = "native",
        stop = function()
            error("synthetic stop callback failure")
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
project = require("typst.project.context").live(project) or project
preview_service.set(project, {
    active = true,
    status = "active",
    active_backend = "native-browser",
    active_cwd = project.root,
    last_backend = "native-browser",
})

local stop_calls = 0
local original_stop = native.stop
native.stop = function(...)
    stop_calls = stop_calls + 1
    return original_stop(...)
end

local ok, result = xpcall(function()
    return controller.stop(project, { notify = false })
end, debug.traceback)
native.stop = original_stop
assert(ok, result)

assert(stop_calls == 1, "native stop should run despite callback error")
assert(type(result) == "table", "stop should return callback error metadata")
assert(result.reason == "callback_error", "stop should preserve callback error")
assert(result.stopped == true, "native backend stop should be confirmed")
assert(
    result.backend_stopped == true,
    "result should report backend stopped despite callback error"
)

local preview = preview_service.get(project)
assert(preview.active == false, "preview should remain inactive after stop")
assert(
    preview.status ~= "stopping_failed",
    "stopped native preview should not be resurrected as stopping_failed"
)
assert(
    preview.last_result and preview.last_result.reason == "callback_error",
    "preview state should retain callback error metadata"
)

cleanup()
vim.cmd("qa!")
