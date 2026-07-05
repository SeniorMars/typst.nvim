local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")

local dot_cancel_opts = nil
local dot_result = nil
adapter.invoke(
    function()
        return {
            pending = true,
            on_finish_style = "dot",
            cancel_style = "dot",
            cancel = function(opts)
                dot_cancel_opts = opts
                return true,
                    {
                        ok = false,
                        reason = opts and opts.reason or "cancelled",
                        stopped = true,
                    }
            end,
        }
    end,
    "run",
    nil,
    nil,
    {
        kind = "provider-cancel-style",
        provider_name = "dot-timeout",
        args = {},
        timeout_ms = 5,
        on_result = function(result)
            dot_result = result
        end,
    }
)

assert(
    vim.wait(500, function()
        return dot_result ~= nil
    end, 5),
    "dot-style provider timeout should finish"
)
assert(
    dot_cancel_opts and dot_cancel_opts.reason == "timeout",
    "provider adapter timeout should call dot-style cancel(opts)"
)

---@type any
local no_cancel_result = nil
adapter.invoke(
    function()
        return {
            pending = true,
            on_finish = function() end,
        }
    end,
    "run",
    nil,
    nil,
    {
        kind = "provider-cancel-style",
        provider_name = "no-cancel",
        args = {},
        timeout_ms = 5,
        on_result = function(result)
            no_cancel_result = result
        end,
    }
)
assert(
    vim.wait(500, function()
        return no_cancel_result ~= nil
    end, 5),
    "provider pending handles without cancel should still time out"
)
assert(
    no_cancel_result.reason == "timeout" and no_cancel_result.stopped ~= true,
    "provider adapter timeout should not confirm stop for no-cancel pending handles"
)

local explicit_cancel = adapter.invoke(
    function()
        return {
            pending = true,
            on_finish_style = "dot",
            cancel = function()
                return true, { stopped = true }
            end,
        }
    end,
    "run",
    nil,
    nil,
    {
        kind = "provider-cancel-style",
        provider_name = "dot-missing-style",
        args = {},
        return_mode = "handle",
        timeout_ms = 0,
    }
)
local stopped, cancel_result = explicit_cancel.cancel({ reason = "unit" })
assert(stopped == false, "dot-style cancel without cancel_style should fail")
assert(
    cancel_result.reason == "dot_cancel_requires_explicit_style",
    "provider adapter should surface explicit cancel-style failures"
)

local colon_seen_self = false
local colon_handle = adapter.invoke(
    function()
        local handle = { pending = true }
        function handle:cancel(opts)
            colon_seen_self = self == handle and opts.reason == "unit"
            return true,
                {
                    ok = false,
                    reason = opts.reason,
                    stopped = true,
                }
        end
        return handle
    end,
    "run",
    nil,
    nil,
    {
        kind = "provider-cancel-style",
        provider_name = "colon",
        args = {},
        return_mode = "handle",
        timeout_ms = 0,
    }
)
stopped, cancel_result = colon_handle.cancel({ reason = "unit" })
assert(stopped == true, "colon-style cancellation should still work")
assert(colon_seen_self, "colon-style cancellation should receive self")
assert(
    cancel_result.reason == "unit",
    "colon cancellation result should pass through"
)

vim.cmd("qa!")
