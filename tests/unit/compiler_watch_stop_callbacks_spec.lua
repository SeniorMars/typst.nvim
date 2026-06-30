local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local operation = require("typst.core.operation")
local process = require("typst.core.process")
local typst_watcher = require("typst.compiler.typst")
local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_service = require("typst.project.services.compiler")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("watch-stop-callbacks"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local original_run = operation.run
local original_kill = process.kill
local original_start_poll = compiler_dependencies.start_poll
local original_stop_poll = compiler_dependencies.stop_poll
local original_refresh_watcher = compiler_dependencies.refresh_watcher

local finish
local cleanup
local kill_calls = 0
local handle = {
    pid = 55123,
    closing = false,
    is_closing = function(self)
        return self.closing
    end,
}

operation.run = function(_, _, _, opts)
    finish = opts.on_finish
    cleanup = opts.cleanup
    return { handle = handle }
end
process.kill = function()
    kill_calls = kill_calls + 1
    return true
end
compiler_dependencies.start_poll = function() end
compiler_dependencies.stop_poll = function() end
compiler_dependencies.refresh_watcher = function() end

local ok, err = xpcall(function()
    typst_watcher.start(project)

    local watcher = assert(
        (compiler_service.get(project) or {}).watcher,
        "watcher should be registered"
    )
    local cycle_timer = assert((vim.uv or vim.loop).new_timer())
    cycle_timer:start(60000, 0, function() end)
    watcher.current_cycle = {
        id = 1,
        generation = 1,
        finish_timer = cycle_timer,
    }

    local callbacks = {}
    typst_watcher.stop(project, function(result)
        callbacks[#callbacks + 1] = { id = "first", result = result }
    end)
    typst_watcher.stop(project, function(result)
        callbacks[#callbacks + 1] = { id = "second", result = result }
    end)

    assert(kill_calls == 1, "repeated watcher stop should signal once")
    assert(watcher.kill_timer, "watcher should hold fallback kill timer")

    handle.closing = true
    finish({ code = 0, stdout = "", stderr = "" })
    if cleanup then
        cleanup()
    end

    assert(#callbacks == 2, "both watcher stop callbacks should run")
    assert(callbacks[1].id == "first", "first callback should run first")
    assert(callbacks[2].id == "second", "second callback should run second")
    assert(
        callbacks[1].result.stopped == true
            and callbacks[2].result.stopped == true,
        "watcher stop callbacks should receive stopped payloads"
    )
    assert(watcher.kill_timer == nil, "watcher kill timer should be cleared")
    assert(
        watcher.current_cycle.finish_timer == nil,
        "cycle finish timer should be cleared"
    )
    assert(cycle_timer:is_closing(), "cycle finish timer should be closed")

    finish({ code = 0, stdout = "", stderr = "" })
    assert(#callbacks == 2, "late watcher exit should not rerun callbacks")
end, debug.traceback)

operation.run = original_run
process.kill = original_kill
compiler_dependencies.start_poll = original_start_poll
compiler_dependencies.stop_poll = original_stop_poll
compiler_dependencies.refresh_watcher = original_refresh_watcher

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
