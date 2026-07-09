local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")

local thrown = adapter.invoke(
    function()
        error("provider exploded")
    end,
    nil,
    {},
    {},
    {
        kind = "lint",
        provider_name = "throwing",
    }
)
assert(thrown.reason == "provider_error", "provider throws should be captured")
assert(
    thrown.provider == "throwing",
    "provider error should keep provider name"
)

local callback_results = {}
local duplicate = adapter.invoke(
    function(_, _, callback)
        callback({ ok = true, value = 1 })
        callback({ ok = true, value = 2 })
        return { pending = true }
    end,
    nil,
    {},
    {},
    {
        kind = "format",
        provider_name = "duplicate",
        on_result = function(result)
            callback_results[#callback_results + 1] = result
        end,
    }
)
assert(duplicate.ok == true, "synchronous callback result should be returned")
assert(#callback_results == 1, "provider callback should run once")
assert(
    callback_results[1].value == 1,
    "first provider callback result should win"
)

local nil_callback = adapter.invoke(
    function(_, _, callback)
        callback(nil)
        return { pending = true }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "nil-callback",
        invalid_result_message = "nil callback result",
    }
)
assert(
    nil_callback.reason == "invalid_result",
    "nil callback results should be normalized as invalid"
)

---@type any
local timed_out = nil
local pending = adapter.invoke(
    function()
        return nil
    end,
    nil,
    {},
    {},
    {
        kind = "lint",
        provider_name = "silent",
        timeout_ms = 10,
        on_result = function(result)
            timed_out = result
        end,
    }
)
assert(pending.pending, "silent async provider should return a pending result")
assert(
    pending._typst_provider_lifecycle == true
        and pending._typst_handle_contract == "provider-pending",
    "silent async providers should use the shared provider pending lifecycle"
)
assert(
    type(pending.on_result) == "function",
    "provider lifecycle pending handles should expose on_result"
)
assert(
    vim.wait(1000, function()
        return timed_out ~= nil
    end, 5),
    "silent provider did not time out"
)
assert(timed_out.reason == "timeout", "silent provider should time out")

---@type any
local returned_pending_timeout = nil
local returned_pending_on_result = nil
local returned_pending_on_result_handle = nil
local returned_pending_raw_on_result_called = false
local returned_pending = adapter.invoke(
    function()
        return {
            pending = true,
            on_result = function()
                returned_pending_raw_on_result_called = true
            end,
            cancel = function()
                return true, { stopped = true }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "export",
        provider_name = "returned-pending",
        timeout_ms = 10,
        on_result = function(result)
            returned_pending_timeout = result
        end,
    }
)
assert(
    returned_pending.pending,
    "returned pending provider should return its pending handle"
)
assert(
    returned_pending._typst_provider_lifecycle == true
        and returned_pending._typst_handle_contract == "provider-pending"
        and type(returned_pending.on_finish) == "function",
    "returned provider handles should be wrapped in the shared lifecycle proxy"
)
assert(
    adapter.result_like({ pending = true, reason = "starting" }) == false,
    "pending provider handles with reason metadata should not be result-like"
)
local returned_pending_finished = nil
local returned_pending_finished_handle = nil
returned_pending:on_finish(function(result, handle)
    returned_pending_finished = result
    returned_pending_finished_handle = handle
end)
returned_pending:on_result(function(result, handle)
    returned_pending_on_result = result
    returned_pending_on_result_handle = handle
end)
assert(
    vim.wait(1000, function()
        return returned_pending_timeout ~= nil
    end, 5),
    "returned pending provider did not time out"
)
assert(
    returned_pending_timeout.reason == "timeout",
    "returned pending provider should time out"
)
assert(
    returned_pending_timeout.stopped == true
        and type(returned_pending_timeout.cancel_result) == "table"
        and returned_pending_timeout.cancel_result.stopped == true,
    "provider timeout should preserve confirmed cancellation result"
)
assert(
    returned_pending_finished == returned_pending_timeout,
    "provider lifecycle proxy should expose the shared on_finish result"
)
assert(
    returned_pending_finished_handle == returned_pending,
    "provider lifecycle proxy should expose itself as the on_finish handle"
)
assert(
    returned_pending_on_result == returned_pending_timeout
        and returned_pending_on_result_handle == returned_pending,
    "provider lifecycle proxy should expose normalized on_result callbacks"
)
assert(
    returned_pending_raw_on_result_called == false,
    "provider lifecycle proxy should override raw provider on_result callbacks"
)
assert(
    returned_pending.timeout == true and returned_pending.stopped == true,
    "provider lifecycle proxy should copy canonical timeout/stop fields"
)

---@type any
local normalized_without_callback = nil
local returned_without_callback = adapter.invoke(
    function()
        return {
            pending = true,
            cancel = function()
                return true, { stopped = true }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "returned-pending-no-callback",
        timeout_ms = 10,
        normalize = function(result)
            normalized_without_callback = result
            return result
        end,
    }
)
assert(
    returned_without_callback.pending,
    "returned pending provider without callback should return its pending handle"
)
assert(
    vim.wait(1000, function()
        return normalized_without_callback ~= nil
    end, 5),
    "returned pending provider without callback did not time out"
)
assert(
    normalized_without_callback.reason == "timeout",
    "returned pending provider without callback should still time out"
)

local metadata_pending = adapter.invoke(
    function()
        return {
            pending = true,
            reason = "starting",
            message = "provider is starting",
            code = 102,
            cancel = function()
                return true, { stopped = true }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "compiler",
        provider_name = "metadata-pending",
        return_mode = "handle",
        expect_handle = true,
        async = false,
    }
)
assert(
    metadata_pending
        and metadata_pending.pending == true
        and metadata_pending.reason == "starting"
        and metadata_pending.message == "provider is starting",
    "pending provider handles with terminal-looking metadata should remain handles"
)

local invalid_handle_callback = nil
local invalid_handle = adapter.invoke(
    function()
        return "bad-handle"
    end,
    nil,
    {},
    {},
    {
        kind = "compiler",
        provider_name = "invalid-handle",
        return_mode = "handle",
        expect_handle = true,
        async = false,
        on_result = function(result)
            invalid_handle_callback = result
        end,
    }
)
assert(
    type(invalid_handle) == "table"
        and invalid_handle.reason == "invalid_result"
        and invalid_handle.provider == "invalid-handle",
    "invalid handle-mode provider returns should become terminal invalid results"
)
assert(
    invalid_handle.contract == "provider-result-v1"
        and invalid_handle.classification == "invalid_handle",
    "invalid handle-mode provider returns should include strict contract metadata"
)
assert(
    invalid_handle_callback == invalid_handle,
    "invalid handle-mode provider returns should notify through the adapter"
)

local cancelled_result = nil
local cancel_reason = nil
local cancel_count = 0
local cancellable = adapter.invoke(
    function()
        return {
            ok = true,
            pending = true,
            cancel = function(_, opts)
                cancel_count = cancel_count + 1
                cancel_reason = opts and opts.reason
                return true,
                    {
                        ok = false,
                        reason = cancel_reason,
                        stopped = true,
                    }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "template",
        provider_name = "returned-cancellable",
        timeout_ms = 1000,
        on_result = function(result)
            cancelled_result = result
        end,
    }
)
assert(cancellable.pending, "returned pending provider should start pending")
assert(
    cancellable._typst_provider_lifecycle == true,
    "cancellable provider handles should use the shared lifecycle proxy"
)
local cancelled = cancellable.cancel({ reason = "user_cancelled" })
assert(cancelled, "returned pending provider proxy should report cancellation")
assert(
    cancellable.pending == false,
    "returned pending provider proxy should clear pending on cancellation"
)
assert(
    cancelled_result and cancelled_result.reason == "user_cancelled",
    "returned pending provider cancellation should finish through the adapter"
)
assert(
    cancel_reason == "user_cancelled",
    "returned pending provider cancellation should reach the provider handle"
)
local cancelled_again = cancellable.cancel({ reason = "after_finish" })
assert(
    cancelled_again and cancel_count == 1,
    "finished provider lifecycle proxy cancellation should be idempotent"
)

local handle_cancel_opts = nil
local pending_handle_timeout = nil
local pending_handle = adapter.invoke(
    function()
        return {
            pending = true,
            path = "/tmp/typst.nvim-provider-output.pdf",
            cancel = function(_, opts)
                handle_cancel_opts = opts
                return true, { stopped = true }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "pending-handle",
        return_mode = "handle",
        expect_handle = true,
        timeout_ms = 10,
        on_result = function(result)
            pending_handle_timeout = result
        end,
    }
)
assert(
    pending_handle
        and pending_handle.path == "/tmp/typst.nvim-provider-output.pdf",
    "handle return mode should preserve explicit pending handles with path fields"
)
assert(
    vim.wait(1000, function()
        return pending_handle_timeout ~= nil
    end, 5),
    "pending provider handle did not time out"
)
assert(
    handle_cancel_opts and handle_cancel_opts.reason == "timeout",
    "provider timeout cancellation should pass cancel options"
)

local unconfirmed_timeout_result = nil
local unconfirmed_timeout_handle = adapter.invoke(
    function()
        return {
            pending = true,
            cancel = function()
                return false,
                    {
                        ok = false,
                        stopped = false,
                        reason = "shutdown_failed",
                    }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "pending-handle-unconfirmed-timeout",
        timeout_ms = 10,
        on_result = function(result)
            unconfirmed_timeout_result = result
        end,
    }
)
assert(
    unconfirmed_timeout_handle and unconfirmed_timeout_handle.pending == true,
    "unconfirmed timeout provider should start pending"
)
assert(
    vim.wait(1000, function()
        return unconfirmed_timeout_result ~= nil
    end, 5),
    "unconfirmed timeout provider did not report timeout"
)
assert(
    unconfirmed_timeout_result.stopped == false
        and type(unconfirmed_timeout_result.cancel_result) == "table"
        and unconfirmed_timeout_result.cancel_result.stopped == false,
    "provider timeout should preserve unconfirmed cancellation result"
)

local pending_timeout_result = nil
local pending_timeout_callback = nil
local pending_timeout_handle = adapter.invoke(
    function(_, _, callback)
        pending_timeout_callback = callback
        return {
            pending = true,
            cancel = function()
                return false,
                    {
                        ok = false,
                        pending = true,
                        stopped = false,
                        reason = "provider_stopping",
                    }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "pending-handle-pending-timeout-cancel",
        timeout_ms = 10,
        cancel_timeout_ms = 5000,
        on_result = function(result)
            pending_timeout_result = result
        end,
    }
)
assert(
    pending_timeout_handle and pending_timeout_handle.pending == true,
    "pending timeout cancel provider should start pending"
)
assert(
    vim.wait(1000, function()
        return pending_timeout_handle.state == "cancelling"
    end, 5),
    "provider timeout with pending cancellation should enter cancelling state"
)
assert(
    pending_timeout_result == nil,
    "provider timeout with pending cancellation should not finish early"
)
pending_timeout_callback({
    ok = false,
    stopped = false,
    reason = "provider_stopped_late",
})
assert(
    vim.wait(1000, function()
        return pending_timeout_result ~= nil
    end, 5),
    "provider pending timeout cancellation should finish from late callback"
)
assert(
    pending_timeout_result.reason == "provider_stopped_late",
    "provider late callback should supply final result after pending timeout cancel"
)

local cancel_watchdog_result = nil
local cancel_watchdog_handle = adapter.invoke(
    function()
        return {
            pending = true,
            cancel = function()
                return false,
                    {
                        ok = false,
                        pending = true,
                        stopped = false,
                        reason = "provider_stopping",
                    }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "pending-cancel-watchdog",
        timeout_ms = 10,
        cancel_timeout_ms = 10,
        on_result = function(result)
            cancel_watchdog_result = result
        end,
    }
)
assert(
    cancel_watchdog_handle and cancel_watchdog_handle.pending == true,
    "provider pending-cancel watchdog should start from a pending handle"
)
assert(
    vim.wait(1000, function()
        return cancel_watchdog_result ~= nil
    end, 5),
    "provider pending-cancel watchdog should eventually finish"
)
assert(
    cancel_watchdog_result.reason == "cancel_unconfirmed"
        and cancel_watchdog_result.stopped == false
        and cancel_watchdog_handle.pending == false,
    "provider pending-cancel watchdog should report unconfirmed cancellation"
)

local explicit_handle_result = adapter.invoke(
    function()
        return {
            ok = true,
            path = "/tmp/typst.nvim-provider-result.pdf",
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "explicit-result",
        return_mode = "handle",
    }
)
assert(
    explicit_handle_result.ok == true
        and explicit_handle_result.path
            == "/tmp/typst.nvim-provider-result.pdf",
    "handle return mode should still accept explicit result-shaped tables"
)

local ambiguous_table = adapter.invoke(
    function()
        return {
            path = "/tmp/typst.nvim-ambiguous-handle.pdf",
        }
    end,
    nil,
    {},
    {},
    {
        kind = "render",
        provider_name = "ambiguous-table",
        async = false,
    }
)
assert(
    ambiguous_table.reason == "invalid_result",
    "generic provider tables with only structural fields should be invalid by default"
)
assert(
    ambiguous_table.contract == "provider-result-v1",
    "generic structural tables should fail through the strict provider contract"
)

local allowed_table = adapter.invoke(
    function()
        return {
            path = "/tmp/typst.nvim-source-map-target.typ",
            line = 1,
            column = 1,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "source_map",
        provider_name = "location-table",
        async = false,
        result_fields = { path = true, line = true, column = true },
    }
)
assert(
    allowed_table.path == "/tmp/typst.nvim-source-map-target.typ",
    "provider-specific result fields should accept structural table results"
)

vim.cmd("qa!")
