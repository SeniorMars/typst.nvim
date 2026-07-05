local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local process = require("typst.core.process")

local original_kill = process.kill

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local ok, err = xpcall(function()
    local cleaned = false
    local op = operation.new("result-isolation", {
        cleanup = function()
            cleaned = true
        end,
    })
    local id = op.id
    local cancel = op.cancel
    local finish = op.finish

    op:finish({
        ok = true,
        code = 0,
        stdout = "done",
        stderr = "",
        state = "success",
        id = 999,
        cleanup = false,
        cancel = false,
        finish = false,
    })
    assert(cleaned, "operation cleanup should not be overwritten by results")
    assert(op.state == "finished", "result state should not overwrite state")
    assert(op.id == id, "result id should not overwrite operation id")
    assert(op.cancel == cancel, "result cancel should not overwrite method")
    assert(op.finish == finish, "result finish should not overwrite method")
    assert(
        op.result and op.result.state == "success",
        "raw provider result should be preserved separately"
    )

    local late_ok = pcall(function()
        op:on_finish(function()
            error("late callback failure")
        end)
    end)
    assert(late_ok, "late on_finish callbacks should be protected")

    local orphan_cleaned = false
    local orphan_callback = nil
    local orphan = operation.new("orphan", {
        cleanup = function()
            orphan_cleaned = true
        end,
    })
    orphan.handle = {}
    orphan:on_finish(function(finished)
        orphan_callback = finished
    end)
    rawset(process, "kill", function()
        return true
    end)
    local cancel_callbacks = 0
    local cancel_stopped = nil
    local cancel_payload = nil
    local stopping, stopping_result = orphan:cancel(
        { timeout_ms = 1, kill_timeout_ms = 1 },
        function(stopped, result)
            cancel_callbacks = cancel_callbacks + 1
            cancel_stopped = stopped
            cancel_payload = result
        end
    )
    assert(
        not stopping
            and stopping_result
            and stopping_result.pending == true
            and stopping_result.stopping == true,
        "async cancel should report that shutdown is not yet confirmed"
    )
    vim.wait(1000, function()
        return orphan.state == "orphaned-retained"
    end, 1, false)
    flush_scheduled()

    assert(
        orphan.state == "orphaned-retained",
        "unexited process should be retained as an orphan"
    )
    assert(orphan.orphaned == true, "orphaned operation should be marked")
    assert(orphan.stopped == false, "orphaned operation should not be stopped")
    assert(
        operation.active()[orphan.id] == nil,
        "retained orphan should leave the active operation table"
    )
    assert(
        operation.retained()[orphan.id] == orphan,
        "retained orphan should remain visible for later ownership"
    )
    assert(cancel_callbacks == 1, "orphan cancel callback should run once")
    assert(cancel_stopped == false, "orphan cancel callback should fail stop")
    ---@type any
    local payload = cancel_payload
    assert(
        payload == orphan and payload.orphaned == true,
        "orphan cancel callback should receive retained operation"
    )
    assert(
        orphan_callback == nil,
        "orphaned operation should not report finish before process exit"
    )
    assert(
        not orphan_cleaned,
        "orphaned operation should not run destructive cleanup"
    )

    local late_orphan_callback = nil
    orphan:on_finish(function(finished)
        late_orphan_callback = finished
    end)
    assert(
        late_orphan_callback == nil,
        "late on_finish should also wait for real orphan exit"
    )

    orphan:finish({ code = 1, stdout = "", stderr = "late exit" })
    assert(
        orphan_callback == orphan,
        "late process exit should report the terminal result"
    )
    assert(
        late_orphan_callback == orphan,
        "late on_finish should run when retained orphan exits"
    )
    assert(orphan_cleaned, "cleanup should run after the process really exits")
    assert(
        orphan.stopped == false,
        "late orphan exit should not synthesize a successful stop"
    )
    assert(
        orphan.was_orphaned == true,
        "late process exit should retain orphan provenance"
    )
    assert(
        orphan.exited_after_orphan == true,
        "late process exit should be marked as post-orphan exit"
    )
    assert(
        orphan.result
            and orphan.result.was_orphaned == true
            and orphan.result.exited_after_orphan == true
            and orphan.result.stopped == false,
        "late process exit result should preserve orphan semantics"
    )
    assert(
        operation.active()[orphan.id] == nil,
        "finished orphan should leave the active table"
    )
    assert(
        operation.retained()[orphan.id] == nil,
        "finished orphan should leave the retained table"
    )

    local term_cleaned = false
    local term_failed = operation.new("term-failed", {
        cleanup = function()
            term_cleaned = true
        end,
    })
    term_failed.handle = {}
    rawset(process, "kill", function()
        return false, "term denied"
    end)
    local term_cancel_callbacks = 0
    local stopped, cancel_result = term_failed:cancel(
        nil,
        function(stopped_result, result)
            term_cancel_callbacks = term_cancel_callbacks + 1
            assert(stopped_result == false, "TERM callback should fail stop")
            assert(
                result.orphaned == true,
                "TERM callback should report orphan"
            )
        end
    )
    assert(not stopped, "TERM failure should report failed cancellation")
    assert(
        cancel_result and cancel_result.orphaned,
        "TERM failure should report orphaned cancellation"
    )
    assert(
        term_failed.state == "orphaned-retained",
        "TERM failure should retain the orphaned operation"
    )
    assert(not term_cleaned, "TERM failure should not run cleanup")
    assert(
        operation.active()[term_failed.id] == nil,
        "TERM-failed operation should leave active operations"
    )
    assert(
        operation.retained()[term_failed.id] == term_failed,
        "TERM-failed operation should remain retained"
    )
    assert(
        term_cancel_callbacks == 1,
        "TERM-failed cancel callback should run once"
    )

    local sync_finished = operation.new("sync-finish-during-cancel")
    sync_finished.handle = {}
    rawset(process, "kill", function(handle)
        assert(handle == sync_finished.handle, "cancel should kill sync handle")
        sync_finished:finish({ code = 0, stopped = true })
        return true
    end)
    local sync_cancel_callbacks = 0
    local sync_cancel_stopped = nil
    sync_finished:cancel({ timeout_ms = 0 }, function(stopped_result)
        sync_cancel_callbacks = sync_cancel_callbacks + 1
        sync_cancel_stopped = stopped_result
    end)
    assert(
        sync_finished.state == "finished",
        "synchronous process exit during cancel should finish operation"
    )
    assert(
        sync_cancel_callbacks == 1 and sync_cancel_stopped == true,
        "cancel callback registered after sync finish should run immediately"
    )

    local sync_notifications = {}
    local sync_callbacks = {}
    local sync_handle = { pending = true }
    local returned_handle = operation.notify_result(function(done)
        done({ ok = true, value = 1 })
        return sync_handle
    end, {
        notify_result = function(result)
            sync_notifications[#sync_notifications + 1] = result
        end,
        callback = function(result)
            sync_callbacks[#sync_callbacks + 1] = result
        end,
    })
    assert(
        returned_handle == sync_handle,
        "synchronous provider callbacks should preserve the returned handle"
    )
    assert(
        #sync_notifications == 1
            and sync_notifications[1].ok == true
            and sync_notifications[1].value == 1,
        "synchronous provider callbacks should notify exactly once"
    )
    assert(
        #sync_callbacks == 1 and sync_callbacks[1] == sync_notifications[1],
        "synchronous provider callbacks should call user callback exactly once"
    )

    local start_messages = {}
    local pending_notifications = 0
    local pending_handle = operation.notify_result(function()
        return { pending = true }
    end, {
        start_message = "starting work",
        notify = function(message)
            start_messages[#start_messages + 1] = message
        end,
        notify_result = function()
            pending_notifications = pending_notifications + 1
        end,
    })
    assert(
        type(pending_handle) == "table" and pending_handle.pending == true,
        "pending provider result should be returned unchanged"
    )
    assert(
        #start_messages == 1 and start_messages[1] == "starting work",
        "pending provider result should emit the start notification"
    )
    assert(
        pending_notifications == 0,
        "pending provider result should not emit terminal notification"
    )

    local terminal_notifications = {}
    local terminal_result = { ok = false, reason = "failed" }
    local returned_terminal = operation.notify_result(function()
        return terminal_result
    end, {
        notify_result = function(result)
            terminal_notifications[#terminal_notifications + 1] = result
        end,
    })
    assert(
        returned_terminal == terminal_result,
        "terminal provider result should be returned unchanged"
    )
    assert(
        #terminal_notifications == 1
            and terminal_notifications[1] == terminal_result,
        "terminal provider result should notify exactly once"
    )
end, debug.traceback)

process.kill = original_kill

if not ok then
    error(err)
end

local original_shutdown = process.shutdown

ok, err = xpcall(function()
    local op = operation.new("cancel-wait-payload")
    op.handle = {}
    op.state = "running"
    op.stdout = "partial stdout"
    op.stderr = "partial stderr"

    rawset(process, "shutdown", function(handle, opts)
        assert(
            handle == op.handle,
            "cancel should shut down the operation handle"
        )
        assert(
            opts.reason == "test-cancel",
            "cancel reason should reach shutdown"
        )
        return false,
            {
                stopped = false,
                forced = true,
                error = "still running",
                raw_only = true,
            }
    end)
    local callback_stopped = nil
    local callback_payload = nil
    local stopped, payload = op:cancel({
        wait = true,
        reason = "test-cancel",
    }, function(done, result)
        callback_stopped = done
        callback_payload = result
    end)
    assert(stopped == false, "wait cancel should report failed stop")
    assert(
        payload == callback_payload,
        "callback should receive returned payload"
    )
    assert(callback_stopped == false, "callback stop flag should match return")
    assert(payload.code == 1, "failed wait cancel should normalize code")
    assert(
        payload.stdout == "partial stdout",
        "cancel payload should preserve operation stdout"
    )
    assert(
        payload.stderr == "partial stderr",
        "cancel payload should preserve operation stderr"
    )
    assert(payload.stopped == false, "cancel payload should mark not stopped")
    assert(
        payload.forced == true,
        "cancel payload should preserve forced state"
    )
    assert(
        payload.error == "still running",
        "cancel payload should preserve error"
    )
    assert(payload.orphaned == true, "failed wait cancel should mark orphaned")
    assert(
        payload.reason == "test-cancel",
        "cancel payload should preserve reason"
    )
    assert(
        payload.message == "still running",
        "cancel payload should carry failure message"
    )
    assert(
        payload.raw_only == nil,
        "cancel callback should not receive raw shutdown-only metadata"
    )
    assert(
        op.state == "orphaned-retained",
        "failed wait cancel should retain orphan state"
    )
end, debug.traceback)

process.shutdown = original_shutdown

if not ok then
    error(err)
end

local allowed_colon_waits = {
    ["lua/typst/core/operation.lua"] = {
        ["function Operation:wait(timeout_ms)"] = true,
    },
    ["lua/typst/core/process.lua"] = {
        ["return system:wait(1000)"] = true,
    },
    ["lua/typst/workflows/render.lua"] = {
        ["return system:wait(1000)"] = true,
    },
}

local function relative(path)
    path = vim.fs.normalize(path)
    local prefix = vim.fs.normalize(root) .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

local violations = {}
for _, path in
    ipairs(vim.fn.globpath(root .. "/lua/typst", "**/*.lua", false, true))
do
    local rel = relative(path)
    for lnum, line in ipairs(vim.fn.readfile(path)) do
        if line:find(":wait%(") then
            local allowed_lines = allowed_colon_waits[rel] or {}
            local trimmed = vim.trim(line)
            if not allowed_lines[trimmed] then
                violations[#violations + 1] = ("%s:%d: %s"):format(
                    rel,
                    lnum,
                    trimmed
                )
            end
        end
    end
end

assert(
    #violations == 0,
    "runtime managed-operation waits should stay out of interactive paths: "
        .. table.concat(violations, "; ")
)

vim.cmd("qa!")
