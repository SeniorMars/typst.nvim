local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local provider = {
    name = "capabilities-outputless-provider",
    outputless = true,
    compile = function() end,
    start = function() end,
    stop = function() end,
    status = function()
        return "idle"
    end,
}

typst.reset({ force = true })
typst.setup({
    root = root,
    compile = {
        provider = provider,
    },
    preview = {
        provider = "typst-preview.nvim",
        native = "auto",
    },
    diagnostics = {
        enabled = false,
        source = "fallback",
        external_paths = "quickfix-only",
    },
})

local capabilities = typst.capabilities()
assert(
    capabilities.preview.native_auto == true,
    "preview.native=auto should be reported explicitly"
)
assert(
    capabilities.preview.native_browser == true,
    "preview.native=auto should report browser capability"
)
assert(
    capabilities.preview.native_viewer == true,
    "preview.native=auto should report viewer fallback capability"
)
assert(
    capabilities.preview.typst_preview == true,
    "preview.provider=typst-preview.nvim should report typst-preview capability"
)
assert(
    capabilities.diagnostics.compiler == false,
    "diagnostics.enabled=false should disable compiler diagnostics capability"
)
assert(
    capabilities.diagnostics.external_paths == "quickfix-only",
    "capabilities should expose diagnostics external path mode"
)
assert(
    capabilities.compiler.outputless == true,
    "outputless compiler providers should be visible in capabilities"
)
assert(
    capabilities.compiler.output == false,
    "outputless compiler providers without output() should not report output"
)

local executed = false
typst.reset({ force = true })
typst.setup({
    root = root,
    compile = {
        provider = function()
            executed = true
            return provider
        end,
    },
})

local callback_capabilities = typst.capabilities()
assert(executed == false, "capabilities() must not execute function providers")
assert(
    callback_capabilities.compiler.inspectable == false,
    "callback provider should be marked uninspectable"
)
assert(
    callback_capabilities.compiler.reason == "callback_uninspectable",
    "callback provider should report a stable uninspectable reason"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    compile = {
        provider = "generic",
    },
})

local provider_binding_name = "typst.compiler.provider_binding"
local original_provider_binding = package.loaded[provider_binding_name]
package.loaded[provider_binding_name] = {
    configured = function()
        error("forced provider resolution failure")
    end,
    label = function()
        return "unreachable"
    end,
}

local ok, err = xpcall(function()
    local degraded = typst.capabilities()
    assert(
        degraded.compiler.ok == false,
        "capabilities should degrade instead of throwing on provider failure"
    )
    assert(
        degraded.compiler.reason == "provider_resolution_failed",
        "provider failures should be reported with a stable reason"
    )
end, debug.traceback)

package.loaded[provider_binding_name] = original_provider_binding
if not ok then
    error(err)
end

typst.reset({ force = true })
vim.cmd("qa!")
