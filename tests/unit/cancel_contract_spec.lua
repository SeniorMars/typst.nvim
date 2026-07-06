local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local cancel = require("typst.core.cancel")

local dot_opts = nil
local stopped, result = cancel.call({
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
stopped, result = cancel.call(method_handle, { reason = "unit-method" })
assert(stopped == true, "method cancel should confirm stop")
assert(method_seen_self, "method cancel should receive self")
assert(
    result.reason == "unit-method",
    "method cancel result should pass through"
)

stopped, result = cancel.call({
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
stopped, result = cancel.call(fallback_handle, { reason = "unit-fallback" })
assert(stopped == true, "implicit cancel should try receiver fallback")
assert(fallback_calls == 2, "fallback cancel should try both receivers")
assert(
    result.reason == "unit-fallback",
    "fallback cancel result should pass through"
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
    cancel.call(table_receiver_handle, { reason = "unit-table-fallback" })
assert(
    stopped == true,
    "single-table wrong_receiver result should try receiver fallback"
)
assert(
    table_receiver_calls == 2,
    "single-table wrong_receiver fallback should try both receivers"
)
assert(
    result.reason == "unit-table-fallback",
    "single-table fallback cancel result should pass through"
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
    cancel.call(pending_fallback_handle, { reason = "unit-pending-fallback" })
assert(stopped == false, "pending fallback should be unconfirmed")
assert(
    pending_fallback_calls == 2,
    "pending fallback should try both receivers"
)
assert(
    result.pending == true and result.reason == "stop_pending",
    "pending fallback result should be preserved"
)

stopped, result = cancel.call({
    cancel_style = "dot",
    cancel = function() end,
}, { reason = "unit-empty" })
assert(stopped == false, "empty cancel should be unconfirmed")
assert(
    result.reason == "cancel_no_result",
    "empty cancel should normalize to cancel_no_result"
)

stopped, result = cancel.call({
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

stopped, result = cancel.call({
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

stopped, result = cancel.call({
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

stopped, result = cancel.call({
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
assert(result.reason == "timeout", "ok=false cancel payload should pass through")

vim.cmd("qa!")
