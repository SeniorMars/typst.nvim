local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local operation = require("typst.core.operation")
local process = require("typst.core.process")
local typst_watcher = require("typst.compiler.typst")
local watch_stop = require("typst.compiler.watch.stop")
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
local settle
local cleanup
local kill_calls = 0
local handle = {
    pid = 55123,
    closing = false,
    is_closing = function(self)
        return self.closing
    end,
}
local fake_operation = {
    handle = handle,
    result_callbacks = {},
    settle_callbacks = {},
    on_result = function(self, callback)
        self.result_callbacks[#self.result_callbacks + 1] = callback
        return self
    end,
    on_settle = function(self, callback)
        self.settle_callbacks[#self.settle_callbacks + 1] = callback
        return self
    end,
}

rawset(operation, "run", function(_, _, _, opts)
    finish = opts.on_finish
    settle = opts.on_settle
    cleanup = opts.cleanup
    return fake_operation
end)
rawset(process, "kill", function()
    kill_calls = kill_calls + 1
    return true
end)
rawset(compiler_dependencies, "start_poll", function() end)
rawset(compiler_dependencies, "stop_poll", function() end)
rawset(compiler_dependencies, "refresh_watcher", function() end)
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
        stdout = "",
        stderr = "",
        started_at = 0,
        finished = false,
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
    assert(
        watcher.stop_callbacks == nil,
        "operation-backed watcher stop should not use watcher-local queue"
    )
assert(
    #fake_operation.settle_callbacks == 2,
    "watcher stop callbacks should attach to operation settlement"
)
assert(
    #fake_operation.result_callbacks == 0,
    "watcher stop callbacks should not wait for final result when settle is available"
)

handle.closing = true
local stop_result = { code = 0, stdout = "", stderr = "" }
finish(stop_result)
for _, settle_callback in ipairs(fake_operation.settle_callbacks) do
    settle_callback(stop_result, fake_operation)
end
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

    local unconfirmed_operation = {
        result_callbacks = {},
        settle_callbacks = {},
        on_result = function(self, callback)
            self.result_callbacks[#self.result_callbacks + 1] = callback
            return self
        end,
        on_settle = function(self, callback)
            self.settle_callbacks[#self.settle_callbacks + 1] = callback
            return self
        end,
    }
    local unconfirmed_ran = false
    watch_stop.add_callback({
        operation = unconfirmed_operation,
        deps_path = root .. "/tests/.tmp/watch-deps-timeout.json",
    }, function(result)
        unconfirmed_ran = true
        assert(
            result.stopped == false,
            "operation-backed watcher stop should preserve stopped=false"
        )
        assert(
            result.reason == "timeout",
            "operation-backed watcher stop should preserve failure reason"
        )
        assert(
            result.watch == true,
            "operation-backed watcher stop should keep watch metadata"
        )
    end)
    assert(
        #unconfirmed_operation.settle_callbacks == 1,
        "unconfirmed watcher stop should attach to operation settlement"
    )
    assert(
        #unconfirmed_operation.result_callbacks == 0,
        "unconfirmed watcher stop should not wait for final result"
    )
    for _, settle_callback in ipairs(unconfirmed_operation.settle_callbacks) do
        settle_callback({
            ok = false,
            stopped = false,
            reason = "timeout",
            message = "watch stop timed out",
        }, unconfirmed_operation)
    end
    assert(unconfirmed_ran, "unconfirmed watcher stop callback should run")

    local retained_result = {
        ok = false,
        stopped = false,
        orphaned = true,
        retained = true,
        reason = "orphaned",
    }
    watcher.stopping = true
    compiler_service.set(project, {
        watcher = watcher,
        watcher_operation = fake_operation,
        status = "stopping",
    })
    settle(retained_result)
    assert(
        (compiler_service.get(project) or {}).status == "stopping_failed",
        "retained watcher operation settle should record stopping_failed status"
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
    vim.api.nvim_echo({ { tostring(err), "ErrorMsg" } }, true, {})
    vim.cmd("cquit")
end

vim.cmd("qa!")
