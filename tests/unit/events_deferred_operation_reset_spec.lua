local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local events = require("typst.core.events")
local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

typst.reset({ force = true })
events._reset_for_tests()

local project_root = typst_test_cache_path("events-deferred-operation-reset")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root, "p")
local main = project_root .. "/main.typ"
assert(vim.fn.writefile({ "= Deferred Reset" }, main) == 0, "write main")

typst.setup({
    root = project_root,
    root_markers = {},
    executable = helpers.fake_typst_sleep(root),
    output_dir = typst_test_cache_path(
        "events-deferred-operation-reset-output"
    ),
    compile = {
        deps = false,
    },
    completion = {
        package_cache_prewarm = false,
    },
})

vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local project = typst.project.set_main(main)

local operation_service = require("typst.project.services.operations")
local compiler_api = require("typst.compiler.api")
local original_compile = compiler_api.compile
local exception_proxy = nil
local exception_callback = nil
rawset(compiler_api, "compile", function()
    error("synthetic deferred compile failure")
end)
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstEventCompileStarted",
    once = true,
    callback = function()
        exception_proxy = operation_service.compile(
            project,
            {},
            function(result)
                exception_callback = result
            end
        )
        assert(
            type(exception_proxy) == "table" and exception_proxy.pending == true,
            "deferred throwing operation should return a pending proxy"
        )
    end,
})

events.emit("TypstEventCompileStarted", project, { status = "running" })
rawset(compiler_api, "compile", original_compile)
assert(exception_proxy, "event handler should create exception proxy")
assert(
    exception_proxy.pending == false,
    "runner exception should settle deferred proxy"
)
assert(
    exception_proxy.reason == "exception",
    "runner exception should be reported structurally"
)
assert(
    type(exception_callback) == "table"
        and exception_callback.reason == "exception",
    "deferred operation callback should receive exception result"
)

local proxy = nil
local callback_result = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstEventCompileSucceeded",
    once = true,
    callback = function()
        proxy = typst.compiler.compile({ notify = false }, function(result)
            callback_result = result
        end)
        assert(
            type(proxy) == "table" and proxy.pending == true,
            "compile inside user event should return a deferred proxy"
        )
        typst.reset({ force = true })
    end,
})

events.emit("TypstEventCompileSucceeded", project, { status = "success" })
assert(proxy, "event handler should create a proxy")
assert(proxy.pending == false, "reset should settle deferred proxy")
assert(proxy.finished == true, "reset should finish deferred proxy")
assert(proxy.reason == "reset", "deferred proxy should report reset")
assert(
    type(callback_result) == "table" and callback_result.reason == "reset",
    "deferred operation callback should receive reset result"
)

local state = events._state_for_tests()
assert(state.deferred_count == 0, "reset should clear deferred queue")
assert(state.emitting_depth == 0, "reset should clear event depth")

vim.cmd("qa!")
