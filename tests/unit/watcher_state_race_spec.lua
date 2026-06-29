local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local operation = require("typst.core.operation")
local compiler_watch = require("typst.compiler.watch")
local compiler_dependencies = require("typst.compiler.dependencies")
local typst_watcher = require("typst.compiler.typst_watcher")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("watcher-state-race-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local original_run = operation.run
local original_append_stream = compiler_watch.append_stream
local original_start_poll = compiler_dependencies.start_poll

local appended_watcher = nil
local appended_stream = nil
local appended_data = nil

operation.run = function(_, _, system_opts)
    system_opts.stdout(nil, "[12:34:56] compiling ...\n")
    return {
        handle = {
            pid = 12345,
            is_closing = function()
                return false
            end,
        },
    }
end

compiler_watch.append_stream = function(_, watcher, stream, data)
    appended_watcher = watcher
    appended_stream = stream
    appended_data = data
end

compiler_dependencies.start_poll = function() end

local ok, err = xpcall(function()
    typst_watcher.start(project)
    assert(
        vim.wait(1000, function()
            return appended_watcher ~= nil
        end, 10),
        "synchronous watcher stdout was not appended"
    )
    assert(
        appended_watcher.generation ~= nil,
        "early watcher stdout should see initialized watcher state"
    )
    assert(appended_stream == "stdout", "early watcher stream should be stdout")
    assert(
        appended_data == "[12:34:56] compiling ...\n",
        "early watcher stdout data should be preserved"
    )
end, debug.traceback)

operation.run = original_run
compiler_watch.append_stream = original_append_stream
compiler_dependencies.start_poll = original_start_poll

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
