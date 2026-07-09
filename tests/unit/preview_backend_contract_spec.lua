local backend = require("typst.preview.backend")
local browser_backend = require("typst.preview.backends.browser")
local custom_backend = require("typst.preview.backends.custom")
local delegated = require("typst.preview.backends.delegated")
local interface = require("typst.preview.backends.interface")
local viewer_backend = require("typst.preview.backends.viewer")

assert(
    vim.fn.filereadable("lua/typst/preview/backends/registry.lua") == 0,
    "preview backends should stay explicit modules, not a registry"
)
assert(
    require("typst.preview.backends.viewer_fallback")
        == require("typst.preview.backends.viewer"),
    "preview fallback compatibility path should delegate to the boring viewer backend"
)
assert(
    require("typst.preview.backends.callback")
        == require("typst.preview.backends.custom"),
    "callback preview compatibility path should delegate to custom backend"
)
assert(
    require("typst.preview.backends.native").create().compat == true,
    "native preview compatibility path should be an explicit shim"
)
local policy = backend.policy()
assert(
    policy.extensible == false,
    "preview backends should stay an explicit fixed set"
)
assert(policy.default == "viewer", "viewer should stay the default backend")
assert(
    vim.tbl_contains(policy.fixed, "viewer")
        and vim.tbl_contains(policy.fixed, "browser")
        and vim.tbl_contains(policy.fixed, "delegated")
        and vim.tbl_contains(policy.fixed, "custom"),
    "preview backend policy should list the fixed backend kinds"
)
assert(
    policy.advanced.browser
        and policy.advanced.delegated
        and policy.advanced.custom
        and not policy.advanced.viewer,
    "only non-viewer preview backends should be marked advanced"
)
policy.fixed[#policy.fixed + 1] = "registry"
assert(
    not vim.tbl_contains(backend.policy().fixed, "registry"),
    "preview backend policy snapshots should not expose mutable state"
)
assert(
    backend.delegates_to_typst_preview({ provider = "typst-preview.nvim" }),
    "backend helper should detect typst-preview.nvim delegation"
)
assert(
    not backend.delegates_to_typst_preview({ provider = "native" }),
    "backend helper should not treat native as delegated"
)

local browser = browser_backend.create()
local viewer = viewer_backend.create()
assert(browser.kind == "browser", "browser backend should be explicit")
assert(browser.name == "native-browser", "browser backend should name native browser")
assert(browser.advanced == true, "browser backend should be marked advanced")
assert(viewer.kind == "viewer", "viewer backend should be explicit")
assert(viewer.advanced == false, "viewer backend should stay boring")
assert(
    interface.capabilities(browser).open == true,
    "backend interface should expose open capability"
)

local open_seen = false
local wrapped = custom_backend.create({
    open = function(_, opts)
        open_seen = opts and opts.mode == "slide"
        return { ok = true, opened = true }
    end,
    stop = function()
        return { ok = true, stopped = true }
    end,
})
assert(
    wrapped.kind == "custom",
    "custom backend should create a custom backend"
)
assert(
    custom_backend.create({ open = function() end }).kind == "custom",
    "custom backend should be explicit"
)

local open_result = wrapped:open({}, { mode = "slide" })
assert(open_seen, "custom backend should pass open opts")
assert(open_result.opened == true, "custom backend should return open result")

local stop_result = wrapped:stop({}, {})
assert(
    stop_result.stopped == true,
    "custom backend should return stop result"
)

local refresh_result = wrapped:refresh({}, { code = 0 }, {})
assert(
    refresh_result == nil,
    "custom backend should return nil when refresh is not configured"
)

local failed = custom_backend.create({
    open = function()
        error("boom")
    end,
})
local failed_result = failed:open({ main = "main.typ" }, {})
assert(failed_result.ok == false, "custom backend should catch open errors")
assert(
    failed_result.reason == "callback_error",
    "custom backend should normalize callback errors"
)

local refresh_failed = custom_backend.create({
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
    "custom backend should catch refresh errors"
)
assert(
    refresh_failed_result.reason == "callback_error",
    "custom refresh errors should use callback_error"
)
assert(
    refresh_failed_result.action == "refresh",
    "custom refresh errors should preserve action"
)

assert(
    type(delegated.own_command_definition) == "string",
    "delegated backend should expose command definitions"
)
assert(
    delegated.command_available("__TypstPreviewMissingCommand__") == false,
    "delegated backend should report missing commands"
)
