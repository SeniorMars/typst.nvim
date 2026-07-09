local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local preview_pending = require("typst.preview.pending")

local function project(name)
    return {
        key = name,
        root = "/tmp",
        main = "/tmp/" .. name .. ".typ",
        services = {},
    }
end

local function pending_stop_with_pending_cancel()
    local stop_callbacks = {}
    local cancel_callbacks = {}
    local cancel_reason = nil
    local cancel_handle = {
        pending = true,
        on_finish_style = "colon",
    }

    function cancel_handle:on_finish(callback)
        cancel_callbacks[#cancel_callbacks + 1] = callback
        return self
    end

    local stop_handle = {
        pending = true,
        on_finish_style = "colon",
        cancel_style = "colon",
    }

    function stop_handle:on_finish(callback)
        stop_callbacks[#stop_callbacks + 1] = callback
        return self
    end

    function stop_handle:cancel(opts)
        cancel_reason = opts and opts.reason or nil
        return false, cancel_handle
    end

    return stop_handle, stop_callbacks, cancel_callbacks, function()
        return cancel_reason
    end
end

local stop_handle, stop_callbacks, cancel_callbacks, cancel_reason =
    pending_stop_with_pending_cancel()
local wrapper = preview_pending.native_stop_after_pending(
    project("native-stop-original-wins"),
    stop_handle,
    function(_, result)
        return {
            ok = true,
            stopped = true,
            source = result.source,
        }
    end
)

local stopped, cancel_result = wrapper:cancel({ reason = "unit_cancel" })
assert(stopped == false, "pending stop cancellation should be unconfirmed")
assert(
    cancel_result and cancel_result.pending == true,
    "pending stop cancellation should return the provider cancel handle"
)
assert(
    cancel_reason() == "unit_cancel",
    "pending stop cancellation should pass the cancel reason"
)
assert(wrapper.pending == true, "pending stop wrapper should remain pending")
assert(#stop_callbacks == 1, "pending stop should remain observable")
assert(#cancel_callbacks == 1, "pending cancellation should be observable")

stop_callbacks[1]({ source = "stop_finished" })
assert(wrapper.finished == true, "original stop completion should finish wrapper")
assert(
    wrapper.result and wrapper.result.source == "stop_finished",
    "original stop completion should win when it arrives before cancel completion"
)
cancel_callbacks[1]({ ok = false, stopped = true, reason = "late_cancel" })
assert(
    wrapper.result and wrapper.result.source == "stop_finished",
    "late cancel completion should not replace an already finished stop wrapper"
)

stop_handle, stop_callbacks, cancel_callbacks = pending_stop_with_pending_cancel()
wrapper = preview_pending.native_stop_after_pending(
    project("native-stop-cancel-wins"),
    stop_handle,
    function(_, result)
        return {
            ok = true,
            stopped = true,
            source = result.source,
        }
    end
)

stopped, cancel_result = wrapper:cancel({ reason = "unit_cancel" })
assert(stopped == false, "pending cancel should still be unconfirmed")
cancel_callbacks[1]({ ok = false, stopped = true, reason = "cancel_finished" })
assert(wrapper.finished == true, "cancel completion should finish wrapper")
assert(
    wrapper.result and wrapper.result.reason == "cancel_finished",
    "cancel completion should win when it arrives before original stop"
)
stop_callbacks[1]({ source = "late_stop" })
assert(
    wrapper.result and wrapper.result.reason == "cancel_finished",
    "late original stop should not replace cancel completion"
)

vim.cmd("qa!")
