local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler_command = require("typst.compiler.command")
local output_path = require("typst.compiler.output_path")
local path_leases = require("typst.core.path_leases")
local typst_compile = require("typst.compiler.typst_compile")
local typst_watch = require("typst.compiler.watch.runner")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lease-failure-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local run_config = require("typst.config").unsafe_get()
local output = output_path.output_path(project, run_config)
local failed_events = {}
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileFailed",
    callback = function(args)
        failed_events[#failed_events + 1] = args.data
    end,
})

local original_build = compiler_command.build
compiler_command.build = function()
    error("synthetic command build failure")
end

local callback_result = nil
local ok, err = xpcall(function()
    local handle = typst_compile.start(project, function(result)
        callback_result = result
    end, run_config)
    assert(
        handle == nil,
        "compile should not start after command build failure"
    )
    assert(callback_result, "compile failure callback should run")
    assert(
        callback_result.reason == "command_build_failed",
        "failure should identify command construction"
    )
    assert(
        not path_leases.active(output),
        "output lease should be released after command build failure"
    )
    assert(
        failed_events[#failed_events]
            and failed_events[#failed_events].reason
                == "command_build_failed",
        "compile command build failure should emit TypstCompileFailed"
    )

    callback_result = nil
    local watch_handle = typst_watch.start(project, function(result)
        callback_result = result
    end, run_config)
    assert(
        watch_handle == nil,
        "watch should not start after command build failure"
    )
    assert(callback_result, "watch failure callback should run")
    assert(
        callback_result.reason == "command_build_failed",
        "watch failure should identify command construction"
    )
    assert(
        not path_leases.active(output),
        "output lease should be released after watch command build failure"
    )
    assert(
        failed_events[#failed_events]
            and failed_events[#failed_events].reason
                == "command_build_failed",
        "watch command build failure should emit TypstCompileFailed"
    )
end, debug.traceback)

compiler_command.build = original_build

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
