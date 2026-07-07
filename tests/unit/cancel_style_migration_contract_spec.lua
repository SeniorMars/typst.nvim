local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local pending = require("typst.core.pending")
local typst = require("typst")

local function cancel_call(handle, opts, callback)
    return pending.cancel(handle, opts, { callback = callback })
end

typst.reset({ force = true })

local attached = {
    pending = true,
    cancel_style = "dot",
    cancel = function(opts)
        return true,
            {
                ok = true,
                stopped = true,
                reason = opts and opts.reason,
            }
    end,
}
local owned_stopped, owned_result =
    cancel_call(attached, { reason = "owned_cancel" })
assert(owned_stopped == true, "typst-owned attached handles should cancel")
assert(
    owned_result.stopped == true,
    "typst-owned attached handle should confirm stop"
)

local colon_called = false
local colon_handle = {
    pending = true,
    cancel_style = "colon",
    cancel = function(self, opts)
        colon_called = opts and opts.reason == "colon_cancel"
        return true, { ok = true, stopped = true }
    end,
}
local colon_stopped = cancel_call(colon_handle, { reason = "colon_cancel" })
assert(colon_stopped == true, "explicit colon provider should cancel")
assert(colon_called == true, "colon provider should receive cancel options")

local dot_called = false
local dot_handle = {
    pending = true,
    on_finish_style = "dot",
    cancel_style = "dot",
    cancel = function(opts)
        dot_called = opts and opts.reason == "dot_cancel"
        return true, { ok = true, stopped = true }
    end,
}
local dot_stopped = cancel_call(dot_handle, { reason = "dot_cancel" })
assert(dot_stopped == true, "explicit dot provider should cancel")
assert(dot_called == true, "dot provider should receive opts directly")

local unstyled_called = false
local unstyled_dot = {
    pending = true,
    on_finish_style = "dot",
    cancel = function()
        unstyled_called = true
        return true, { ok = true, stopped = true }
    end,
}
local unstyled_stopped, unstyled_result =
    cancel_call(unstyled_dot, { reason = "missing_style" })
assert(
    unstyled_stopped == false,
    "dot-style provider without cancel_style should fail predictably"
)
assert(
    unstyled_result.reason == "dot_cancel_requires_explicit_style",
    "missing cancel_style should be actionable"
)
assert(
    unstyled_called == false,
    "missing cancel_style should not call provider with guessed receiver"
)

typst.reset({ force = true })
vim.cmd("qa!")
