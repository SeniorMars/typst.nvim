local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local compiler_process = require("typst.compiler.typst_process")
local compiler_service = require("typst.project.services.compiler")
local project_services = require("typst.project.services")

local project = {
    key = "compiler-stop-callbacks",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    services = project_services.new_state(),
}
---@type any
local handle = {
    is_closing = function()
        return true
    end,
}
local later_callback_ran = false

log.clear()
compiler_service.set(project, {
    process = handle,
    process_operation = { handle = handle },
    active_compile_deps_path = root .. "/tests/.tmp/compile-deps.json",
    stopping_compile = {
        handle = handle,
        deps_path = root .. "/tests/.tmp/compile-deps.json",
        callbacks = {
            function()
                error("bad stop callback")
            end,
            function(result)
                later_callback_ran = true
                assert(result.stopped == true, "stop payload should be stopped")
            end,
        },
    },
    status = "stopping",
})
local handled = compiler_process.finish_stopped_compile(
    project,
    handle,
    { code = 0, stdout = "", stderr = "" }
)

assert(handled == true, "stopping compile should be handled")
assert(later_callback_ran, "later stop callbacks should still run")
assert(
    (compiler_service.get(project) or {}).status == "idle",
    "compiler state should end idle"
)

local saw_log = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "compile stop callback failed" then
        saw_log = true
        break
    end
end
assert(saw_log, "bad stop callback should be logged")

vim.cmd("qa!")
