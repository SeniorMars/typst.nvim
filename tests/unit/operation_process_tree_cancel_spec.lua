local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local process = require("typst.core.process")

local original_tree_signal = process.terminate_tree_signal
local original_kill = process.kill

local calls = {}
local ok, err = xpcall(function()
    local op = operation.new("process-tree-cancel")
    op.handle = { id = 1 }
    op.state = "running"

    process.terminate_tree_signal = function(handle, signal)
        calls[#calls + 1] = {
            handle = handle,
            signal = signal,
        }
        return true, nil, signal == 9 and "forced-tree" or "tree"
    end
    process.kill = function()
        error("operation cancel should use process-tree signalling")
    end

    local stopped, result = op:cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        stopped == false and result and result.pending == true,
        "async cancel should remain pending until process exit"
    )
    assert(#calls == 1, "cancel should send one graceful tree signal")
    assert(calls[1].handle == op.handle, "tree signal should target the handle")
    assert(calls[1].signal == 15, "graceful cancel should use SIGTERM")

    op:finish({ code = 0, stdout = "", stderr = "", stopped = true })

    calls = {}
    local forced = operation.new("process-tree-force-cancel")
    forced.handle = { id = 2 }
    forced.state = "running"

    local forced_stopped, forced_result = forced:cancel({
        timeout_ms = 0,
        kill_timeout_ms = 1000,
    })
    assert(
        forced_stopped == false
            and forced_result
            and forced_result.pending == true,
        "forced cancel should remain pending until process exit"
    )
    assert(
        #calls == 2,
        "forced cancel should send graceful and forced tree signals"
    )
    assert(
        calls[1].handle == forced.handle and calls[1].signal == 15,
        "forced cancel should attempt graceful tree termination first"
    )
    assert(
        calls[2].handle == forced.handle and calls[2].signal == 9,
        "forced cancel should escalate through tree termination"
    )

    forced:finish({ code = 143, stdout = "", stderr = "", stopped = true })

    calls = {}
    local failed = operation.new("process-tree-cancel-failure")
    failed.handle = { id = 3 }
    failed.state = "running"
    process.terminate_tree_signal = function(_handle, signal)
        calls[#calls + 1] = { signal = signal }
        return false, "tree unavailable"
    end

    local callback_stopped
    local callback_result
    local failed_stopped, failed_result = failed:cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    }, function(stopped, result)
        callback_stopped = stopped
        callback_result = result
    end)
    assert(
        failed_stopped == false,
        "failed tree cancel should not confirm stop"
    )
    assert(
        failed_result and failed_result.orphaned == true,
        "failed tree cancel should return an orphaned result"
    )
    assert(
        failed.state == "orphaned-retained",
        "failed tree cancel should retain the operation as an orphan"
    )
    assert(
        callback_stopped == false
            and callback_result
            and callback_result.orphaned == true,
        "failed tree cancel should settle cancellation callbacks as orphaned"
    )
end, debug.traceback)

process.terminate_tree_signal = original_tree_signal
process.kill = original_kill

if not ok then
    error(err)
end

vim.cmd("qa!")
