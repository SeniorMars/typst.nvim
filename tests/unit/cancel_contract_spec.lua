local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local pending = require("typst.core.pending")

local function cancel_call(handle, opts, callback)
    return pending.cancel(handle, opts, { callback = callback })
end

local dot_opts = nil
local stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function(opts)
        dot_opts = opts
        return true,
            {
                stopped = true,
                reason = opts.reason,
            }
    end,
}, { reason = "unit-dot" })
assert(stopped == true, "dot cancel should confirm stop")
assert(dot_opts.reason == "unit-dot", "dot cancel should receive opts")
assert(result.reason == "unit-dot", "dot cancel result should pass through")

local method_seen_self = false
local method_handle = { cancel_style = "method" }
function method_handle:cancel(opts)
    method_seen_self = self == method_handle and opts.reason == "unit-method"
    return true, {
        stopped = true,
        reason = opts.reason,
    }
end
stopped, result = cancel_call(method_handle, { reason = "unit-method" })
assert(stopped == true, "method cancel should confirm stop")
assert(method_seen_self, "method cancel should receive self")
assert(
    result.reason == "unit-method",
    "method cancel result should pass through"
)

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function()
        return {
            stopped = true,
            reason = "single-table",
        }
    end,
}, { reason = "unit-table" })
assert(stopped == true, "single-table stopped=true cancel should confirm stop")
assert(
    result.reason == "single-table",
    "single-table cancel result should pass through"
)

local fallback_calls = 0
local fallback_handle = {}
function fallback_handle.cancel(self_or_opts, maybe_opts)
    fallback_calls = fallback_calls + 1
    if self_or_opts == fallback_handle then
        return false,
            {
                reason = "wrong_receiver",
                stopped = false,
            }
    end
    return true,
        {
            stopped = true,
            reason = self_or_opts.reason or maybe_opts.reason,
        }
end
stopped, result = cancel_call(fallback_handle, { reason = "unit-fallback" })
assert(stopped == false, "implicit cancel should not guess receiver fallback")
assert(fallback_calls == 1, "implicit cancel should call once")
assert(
    result.reason == "wrong_receiver",
    "implicit cancel should preserve receiver failure"
)

local table_receiver_calls = 0
local table_receiver_handle = {}
function table_receiver_handle.cancel(self_or_opts, maybe_opts)
    table_receiver_calls = table_receiver_calls + 1
    if self_or_opts == table_receiver_handle then
        return {
            stopped = false,
            reason = "wrong_receiver",
        }
    end
    return {
        stopped = true,
        reason = self_or_opts.reason or maybe_opts.reason,
    }
end
stopped, result =
    cancel_call(table_receiver_handle, { reason = "unit-table-fallback" })
assert(
    stopped == false,
    "single-table wrong_receiver result should not try receiver fallback"
)
assert(
    table_receiver_calls == 1,
    "single-table wrong_receiver should call once"
)
assert(
    result.reason == "wrong_receiver",
    "single-table cancel should preserve receiver failure"
)

local pending_fallback_calls = 0
local pending_fallback_handle = {}
function pending_fallback_handle.cancel(self_or_opts, maybe_opts)
    pending_fallback_calls = pending_fallback_calls + 1
    if self_or_opts == pending_fallback_handle then
        return false,
            {
                stopped = false,
                reason = "wrong_receiver",
            }
    end
    assert(
        self_or_opts.reason == "unit-pending-fallback"
            or maybe_opts.reason == "unit-pending-fallback",
        "pending fallback cancel should receive opts"
    )
    return true,
        {
            pending = true,
            reason = "stop_pending",
        }
end
stopped, result =
    cancel_call(pending_fallback_handle, { reason = "unit-pending-fallback" })
assert(stopped == false, "receiver failure should be unconfirmed")
assert(
    pending_fallback_calls == 1,
    "pending fallback should not try guessed receiver"
)
assert(
    result.reason == "wrong_receiver",
    "receiver failure should be preserved instead of guessed fallback"
)

local ambiguous_dot_called = false
stopped, result = cancel_call({
    on_finish_style = "dot",
    cancel = function()
        ambiguous_dot_called = true
        return true,
            {
                stopped = true,
                reason = "should-not-run",
            }
    end,
}, { reason = "unit-ambiguous-dot" })
assert(
    stopped == false,
    "ambiguous dot-style cancel should be rejected without explicit style"
)
assert(
    ambiguous_dot_called == false,
    "ambiguous dot-style cancel should not call the provider"
)
assert(
    result.reason == "dot_cancel_requires_explicit_style",
    "ambiguous dot-style cancel should preserve the pending style error"
)

local callback_seen = false
stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function(opts, callback)
        local payload = {
            stopped = true,
            reason = opts.reason,
        }
        callback(true, payload)
        return true, payload
    end,
}, { reason = "unit-callback" }, function(callback_stopped, callback_result)
    callback_seen = callback_stopped == true
        and callback_result
        and callback_result.reason == "unit-callback"
end)
assert(stopped == true, "dot cancel callback fixture should confirm stop")
assert(
    callback_seen == true,
    "dot cancel should forward cancellation callback through pending"
)
assert(
    result.reason == "unit-callback",
    "dot cancel callback fixture should pass through result"
)

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function() end,
}, { reason = "unit-empty" })
assert(stopped == false, "empty cancel should be unconfirmed")
assert(
    result.reason == "cancel_unconfirmed",
    "empty cancel should normalize through pending cancellation"
)

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function()
        return true,
            {
                orphaned = true,
                reason = "retained",
            }
    end,
}, { reason = "unit-orphan" })
assert(stopped == false, "orphaned cancel should be unconfirmed")
assert(result.orphaned == true, "orphaned cancel payload should pass through")

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function()
        return true,
            {
                stopped = false,
                reason = "still_running",
            }
    end,
}, { reason = "unit-contradictory-stopped" })
assert(
    stopped == false,
    "truthy cancel return with stopped=false payload should be unconfirmed"
)
assert(
    result.reason == "still_running",
    "contradictory cancel payload should pass through"
)

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function()
        return true,
            {
                pending = true,
                reason = "stop_pending",
            }
    end,
}, { reason = "unit-pending" })
assert(stopped == false, "pending cancel payload should be unconfirmed")
assert(result.pending == true, "pending cancel payload should pass through")

stopped, result = cancel_call({
    cancel_style = "dot",
    cancel = function()
        return true,
            {
                ok = false,
                reason = "timeout",
            }
    end,
}, { reason = "unit-timeout" })
assert(
    stopped == false,
    "ok=false cancel payload without stopped=true should be unconfirmed"
)
assert(
    result.reason == "timeout",
    "ok=false cancel payload should pass through"
)

vim.cmd("qa!")
