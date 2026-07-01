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

local timed_out = nil
local pending = adapter.invoke(
    function()
        return nil
    end,
    nil,
    {},
    {},
    {
        kind = "grammar",
        provider_name = "silent",
        timeout_ms = 10,
        on_result = function(result)
            timed_out = result
        end,
    }
)
assert(pending.pending, "silent async provider should return a pending result")
assert(
    vim.wait(1000, function()
        return timed_out ~= nil
    end, 5),
    "silent provider did not time out"
)
assert(timed_out.reason == "timeout", "silent provider should time out")

local returned_pending_timeout = nil
local returned_pending = adapter.invoke(
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
    vim.wait(1000, function()
        return returned_pending_timeout ~= nil
    end, 5),
    "returned pending provider did not time out"
)
assert(
    returned_pending_timeout.reason == "timeout",
    "returned pending provider should time out"
)

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

local cancelled_result = nil
local cancel_reason = nil
local cancellable = adapter.invoke(
    function()
        return {
            ok = true,
            pending = true,
            cancel = function(_, opts)
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

local handle_cancel_opts = nil
local raw_handle_timeout = nil
local raw_handle = adapter.invoke(
    function()
        return {
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
        provider_name = "raw-handle",
        return_mode = "handle",
        expect_handle = true,
        timeout_ms = 10,
        on_result = function(result)
            raw_handle_timeout = result
        end,
    }
)
assert(
    raw_handle and raw_handle.path == "/tmp/typst.nvim-provider-output.pdf",
    "handle return mode should preserve raw handles with path fields"
)
assert(
    vim.wait(1000, function()
        return raw_handle_timeout ~= nil
    end, 5),
    "raw provider handle did not time out"
)
assert(
    handle_cancel_opts and handle_cancel_opts.reason == "timeout",
    "provider timeout cancellation should pass cancel options"
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
