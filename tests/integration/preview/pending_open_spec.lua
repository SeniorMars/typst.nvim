local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function setup_project(open_callback)
    cleanup()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("preview-pending-open-output"),
        preview = {
            open = open_callback,
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    return typst.project.set_main(main)
end

local finish_open = nil
local project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    return handle
end)
local opened_events = 0
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function()
        opened_events = opened_events + 1
    end,
})
local pending = typst.viewer.preview()
assert(
    pending and pending.pending == true,
    "pending callback open should return the provider handle"
)
assert(
    type(finish_open) == "function",
    "pending callback open should be observable"
)
assert(
    typst_test_preview(project).opening == true,
    "pending callback open should mark opening"
)
assert(
    typst_test_preview(project).active == false,
    "pending callback open should not mark active before success"
)
assert(opened_events == 0, "pending open should not emit opened early")

assert(finish_open)({
    ok = false,
    reason = "browser_failed",
    message = "browser failed",
})
assert(
    pending.pending == false,
    "failed pending open should finish the returned handle"
)
assert(
    typst_test_preview(project).active == false,
    "failed pending open should leave preview inactive"
)
assert(
    typst_test_preview(project).opening == false,
    "failed pending open should clear opening"
)
assert(
    typst_test_preview(project).status == "open_failed",
    "failed pending open should record open_failed"
)
assert(opened_events == 0, "failed pending open should not emit opened")

finish_open = nil
opened_events = 0
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    return handle
end)
pending = typst.viewer.preview({ mode = "slide" })
assert(pending and pending.pending == true, "second open should be pending")
assert(finish_open)({
    ok = true,
    opened = true,
})
assert(
    pending.pending == false,
    "successful pending open should finish the returned handle"
)
assert(
    typst_test_preview(project).active == true,
    "successful pending open should mark preview active"
)
assert(
    typst_test_preview(project).opening == false,
    "successful pending open should clear opening"
)
assert(
    typst_test_preview(project).active_backend == "callback",
    "successful pending open should record callback backend"
)
assert(opened_events == 1, "successful pending open should emit opened once")

finish_open = nil
opened_events = 0
local finish_callbacks = {}
local open_calls = 0
project = setup_project(function(_, opts)
    open_calls = open_calls + 1
    local index = open_calls
    local handle = {
        pending = true,
        on_finish_style = "colon",
        mode = opts and opts.mode,
    }
    function handle:on_finish(callback)
        finish_callbacks[index] = callback
        return self
    end
    function handle:cancel()
        return true, { pending = true, reason = "restart" }
    end
    return handle
end)
local first = typst.viewer.preview({ mode = "old" })
assert(first and first.pending == true, "first restart race open should pend")
local reused = typst.viewer.preview({ mode = "ignored" })
assert(reused == first, "opening preview should be reused without restart")
assert(open_calls == 1, "reused opening preview should not call open twice")

local second = typst.viewer.preview({ restart = true, mode = "new" })
assert(second and second.pending == true, "restart should create a second open")
assert(open_calls == 2, "restart should call open again")
assert(
    first.pending == false and first.result and first.result.cancelled == true,
    "restart should cancel the previous pending open"
)
assert(
    first.result.stopped == false
        and first.result.superseded == true
        and first.result.cancel_pending == true
        and first.result.provider_result
        and first.result.provider_result.pending == true,
    "pending provider cancel should not report confirmed stopped"
)
assert(
    typst_test_preview(project).opening == true,
    "restart replacement should mark the new open as opening"
)

finish_callbacks[2]({
    ok = true,
    opened = true,
})
assert(
    typst_test_preview(project).active == true,
    "replacement open success should mark preview active"
)
assert(
    typst_test_preview(project).active_mode == "new",
    "replacement open should own the active mode"
)
assert(opened_events == 1, "replacement open should emit one opened event")

finish_callbacks[1]({
    ok = false,
    reason = "late_failure",
    message = "old open failed late",
})
assert(
    first.result and first.result.cancelled == true,
    "old open should stay cancelled after late completion"
)
assert(
    typst_test_preview(project).active == true,
    "late cancelled open failure should not clear newer active preview"
)
assert(
    typst_test_preview(project).active_mode == "new",
    "late cancelled open failure should not overwrite newer preview mode"
)
assert(opened_events == 1, "late cancelled open should not emit another event")

finish_open = nil
opened_events = 0
local cancel_called = false
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    function handle:cancel(opts)
        cancel_called = opts and opts.reason == "user_stop"
        return true, { ok = true, stopped = true }
    end
    return handle
end)
pending = typst.viewer.preview()
assert(
    pending and pending.pending == true,
    "stop cancel open should pend first"
)
local stop_result =
    typst.viewer.preview_stop({ notify = false, reason = "user_stop" })
assert(
    type(stop_result) == "table" and stop_result.stopped == true,
    "confirmed pending-open cancel should report stopped"
)
assert(cancel_called, "stopping a pending open should cancel the provider")
assert(
    pending.pending == false and pending.result and pending.result.cancelled,
    "stopping a pending open should finish the returned open handle"
)
assert(
    typst_test_preview(project).active == false,
    "stopping a pending open should leave preview inactive"
)
assert(
    typst_test_preview(project).opening == false,
    "stopping a pending open should clear opening"
)
assert(finish_open)({ ok = true, opened = true })
assert(
    typst_test_preview(project).active == false,
    "late open success after stop should not reactivate preview"
)
assert(
    opened_events == 0,
    "late open success after stop should not emit opened"
)

finish_open = nil
opened_events = 0
local finish_cancel = nil
local original_notify = vim.notify
local notifications = {}
rawset(vim, "notify", function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    function handle:cancel()
        local cancel = {
            pending = true,
            on_finish_style = "colon",
        }
        function cancel:on_finish(callback)
            finish_cancel = callback
            return self
        end
        return true, cancel
    end
    return handle
end)
pending = typst.viewer.preview({ notify = false })
stop_result = typst.viewer.preview_stop({ reason = "pending_cancel" })
assert(
    type(stop_result) == "table"
        and stop_result.stopped == false
        and stop_result.cancel_pending == true,
    "pending open cancel should report an unconfirmed stop"
)
assert(
    typst_test_preview(project).opening == true,
    "unconfirmed pending-open cancel should retain opening ownership"
)
assert(
    typst_test_preview(project).status == "open_cancel_pending",
    "unconfirmed pending-open cancel should be visible in preview state"
)
assert(
    pending.pending == true,
    "unconfirmed pending-open cancel should keep the original open observable"
)
assert(
    #notifications >= 1
        and notifications[#notifications].level == vim.log.levels.WARN
        and not notifications[#notifications].message:find(
            "Preview stopped",
            1,
            true
        ),
    "unconfirmed pending-open cancel should warn instead of saying stopped"
)
assert(type(finish_cancel) == "function", "pending cancel should be observed")
finish_cancel({ ok = true, stopped = true })
assert(
    pending.pending == false
        and pending.result
        and pending.result.stopped == true,
    "confirmed pending cancel should finish the original open handle"
)
assert(
    typst_test_preview(project).opening == false,
    "confirmed pending cancel should clear opening ownership"
)
assert(finish_open)({ ok = true, opened = true })
assert(
    typst_test_preview(project).active == false,
    "late open after confirmed cancel should not reactivate preview"
)
rawset(vim, "notify", original_notify)

finish_open = nil
finish_cancel = nil
notifications = {}
original_notify = vim.notify
rawset(vim, "notify", function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)
open_calls = 0
project = setup_project(function()
    open_calls = open_calls + 1
    local index = open_calls
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_callbacks[index] = callback
        return self
    end
    function handle:cancel()
        return true, { pending = true, on_finish_style = "colon" }
    end
    return handle
end)
local first_toggle_pending = typst.viewer.preview({ notify = false })
local second_toggle_pending = typst.viewer.preview_toggle({ restart = true })
assert(
    first_toggle_pending.result
        and first_toggle_pending.result.stopped == false
        and first_toggle_pending.result.superseded == true
        and first_toggle_pending.result.cancel_pending == true,
    "toggle restart should supersede the old pending open without claiming stopped"
)
assert(
    second_toggle_pending and second_toggle_pending.pending == true,
    "toggle restart should return the replacement pending open"
)
assert(
    #notifications >= 1
        and not notifications[#notifications].message:find(
            "Preview stopped",
            1,
            true
        ),
    "toggle restart during pending open should not say stopped"
)
rawset(vim, "notify", original_notify)

finish_open = nil
opened_events = 0
local typst_preview = require("typst.integrations.typst_preview")
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    return handle
end)
pending = typst.viewer.preview()
assert(
    pending and pending.pending == true,
    "clear-state open should pend first"
)
local live_project = require("typst.project.context").live(project)
assert(live_project, "clear_state test should resolve the public snapshot")
assert(
    typst_preview.clear_state(live_project, { reason = "test_cleanup" }) == true,
    "clear_state should clear opening-only preview state"
)
assert(
    pending.pending == false and pending.result and pending.result.cancelled,
    "clear_state should finish the pending open handle as cancelled"
)
assert(finish_open)({ ok = true, opened = true })
assert(
    typst_test_preview(project).active == false,
    "late open success after clear_state should not reactivate preview"
)
assert(
    typst_test_preview(project).opening == false,
    "clear_state should keep opening cleared"
)
assert(opened_events == 0, "late open after clear_state should not emit opened")

finish_open = nil
opened_events = 0
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        finish_open = callback
        return self
    end
    return handle
end)
pending = typst.viewer.preview()
assert(
    pending and pending.pending == true,
    "prune stale-open fixture should pend first"
)
local pruned_project = require("typst.project.context").live(project)
assert(pruned_project, "prune stale-open test should resolve live project")
require("typst.project.store").remove(pruned_project.key)
pruned_project._typst_project_pruned = true

assert(finish_open)({ ok = true, opened = true })
assert(
    pending.pending == false and pending.result and pending.result.stale == true,
    "late open completion after prune should finish as stale"
)
assert(
    typst_test_preview(pruned_project).active ~= true,
    "late open completion after prune should not mark preview active"
)
assert(
    opened_events == 0,
    "late open completion after prune should not emit opened"
)

finish_open = nil
local dot_cancel_opts = nil
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "dot",
        cancel_style = "dot",
    }
    function handle.on_finish(callback)
        finish_open = callback
        return handle
    end
    function handle.cancel(opts)
        dot_cancel_opts = opts
        return true, { ok = true, stopped = true }
    end
    return handle
end)
pending = typst.viewer.preview({ notify = false })
local dot_stop = typst.viewer.preview_stop({
    notify = false,
    reason = "dot_stop",
})
assert(
    type(dot_stop) == "table" and dot_stop.stopped == true,
    "explicit dot-style pending-open cancel should report confirmed stop"
)
assert(
    dot_cancel_opts and dot_cancel_opts.reason == "dot_stop",
    "dot-style pending-open cancel should receive opts without self"
)
assert(
    pending.pending == false
        and pending.result
        and pending.result.cancelled == true,
    "dot-style pending-open cancel should finish the open handle"
)

finish_open = nil
local unsupported_cancel_called = false
project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "dot",
    }
    function handle.on_finish(callback)
        finish_open = callback
        return handle
    end
    function handle.cancel()
        unsupported_cancel_called = true
        return true, { ok = true, stopped = true }
    end
    return handle
end)
pending = typst.viewer.preview({ notify = false })
local unsupported_stop = typst.viewer.preview_stop({
    notify = false,
    reason = "unsupported_dot_cancel",
})
assert(
    type(unsupported_stop) == "table"
        and unsupported_stop.ok == false
        and unsupported_stop.stopped == false
        and unsupported_stop.reason == "dot_cancel_requires_explicit_style",
    "dot-style observation without cancel_style should fail clearly"
)
assert(
    unsupported_cancel_called == false,
    "unsupported dot-style cancel should not call provider with guessed args"
)
assert(
    typst_test_preview(project).opening == true,
    "unsupported cancel should retain pending-open ownership"
)

cleanup()
vim.cmd("qa!")
