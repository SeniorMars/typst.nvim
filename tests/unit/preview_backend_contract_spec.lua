local backend = require("typst.preview.backend")
local callback_backend = require("typst.preview.backends.callback")
local delegated = require("typst.preview.backends.delegated")

assert(
    backend.delegates_to_typst_preview({ provider = "typst-preview.nvim" }),
    "backend helper should detect typst-preview.nvim delegation"
)
assert(
    not backend.delegates_to_typst_preview({ provider = "native" }),
    "backend helper should not treat native as delegated"
)

local open_seen = false
local wrapped = callback_backend.create({
    open = function(_, opts)
        open_seen = opts and opts.mode == "slide"
        return { ok = true, opened = true }
    end,
    stop = function()
        return { ok = true, stopped = true }
    end,
})

local open_result = wrapped:open({}, { mode = "slide" })
assert(open_seen, "callback backend should pass open opts")
assert(open_result.opened == true, "callback backend should return open result")

local stop_result = wrapped:stop({}, {})
assert(
    stop_result.stopped == true,
    "callback backend should return stop result"
)

local refresh_result = wrapped:refresh({}, { code = 0 }, {})
assert(
    refresh_result == nil,
    "callback backend should return nil when refresh is not configured"
)

local failed = callback_backend.create({
    open = function()
        error("boom")
    end,
})
local failed_result = failed:open({ main = "main.typ" }, {})
assert(failed_result.ok == false, "callback backend should catch open errors")
assert(
    failed_result.reason == "callback_error",
    "callback backend should normalize callback errors"
)

local refresh_failed = callback_backend.create({
    refresh = function()
        error("refresh exploded")
    end,
})
local refresh_failed_result = refresh_failed:refresh(
    { main = "main.typ" },
    {},
    {}
)
assert(
    refresh_failed_result.ok == false,
    "callback backend should catch refresh errors"
)
assert(
    refresh_failed_result.reason == "callback_error",
    "callback refresh errors should use callback_error"
)
assert(
    refresh_failed_result.action == "refresh",
    "callback refresh errors should preserve action"
)

assert(
    type(delegated.own_command_definition) == "string",
    "delegated backend should expose command definitions"
)
assert(
    delegated.command_available("__TypstPreviewMissingCommand__") == false,
    "delegated backend should report missing commands"
)
