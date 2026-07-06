local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local registry = require("typst.core.cache_registry")

local status = registry.status()
assert(#status.entries > 0, "cache registry should expose registered entries")
---@type any
local stats = registry.stats()
assert(stats.total == #status.entries, "cache stats should count entries")
assert(stats.loaded == #status.loaded, "cache stats should count loaded")
assert(stats.unloaded == #status.unloaded, "cache stats should count unloaded")
assert(stats.reset > 0, "cache stats should count reset-capable entries")
assert(stats.clear > 0, "cache stats should count clear-capable entries")
assert(stats.reload > 0, "cache stats should count reload-capable entries")
assert(stats.forget > 0, "cache stats should count buffer-forget entries")
assert(stats.detach > 0, "cache stats should count buffer-detach entries")
assert(
    stats.forget_window > 0,
    "cache stats should count window-forget entries"
)
assert(
    stats.optional + stats.required == stats.total,
    "cache stats should partition optional and required entries"
)

local by_name = {}
for _, entry in ipairs(status.entries) do
    by_name[entry.name] = entry
end

for _, name in ipairs({
    "metadata",
    "completion",
    "package",
    "symbol",
    "index",
    "import_scan",
    "treesitter",
    "conceal",
    "project_attachments",
}) do
    assert(by_name[name], ("cache registry missing %s entry"):format(name))
end

assert(
    by_name.project_attachments.forget == true,
    "project attachments should register buffer forget cleanup"
)
assert(
    by_name.conceal.detach == true,
    "conceal should register buffer detach cleanup"
)
assert(
    by_name.conceal.forget == true,
    "conceal should register buffer forget cleanup"
)
assert(
    by_name.conceal.forget_window == true,
    "conceal should register window cleanup"
)

local cleared = registry.clear({ bufnr = vim.api.nvim_get_current_buf() })
assert(cleared.metadata == true, "registry clear should reset metadata")
assert(cleared.completion == true, "registry clear should reset completion")
assert(cleared.package == true, "registry clear should reset packages")
assert(cleared.symbol == true, "registry clear should reset symbols")
assert(cleared.index == true, "registry clear should reset project index")
assert(cleared.import_scan == true, "registry clear should reset import scan")
assert(cleared.treesitter == true, "registry clear should forget Tree-sitter")
assert(cleared.conceal == true, "registry clear should refresh conceal")

local reloaded = registry.reload({ bufnr = vim.api.nvim_get_current_buf() })
assert(reloaded.metadata == true, "registry reload should reset metadata")
assert(reloaded.completion == true, "registry reload should reset completion")
assert(reloaded.package == true, "registry reload should reset packages")
assert(reloaded.symbol == true, "registry reload should reset symbols")
assert(reloaded.index == true, "registry reload should reset project index")
assert(reloaded.import_scan == true, "registry reload should reset import scan")
assert(reloaded.treesitter == true, "registry reload should forget Tree-sitter")
assert(reloaded.conceal == true, "registry reload should refresh conceal")
assert(
    pcall(function()
        registry.reload()
    end),
    "registry reload should accept nil opts"
)

local test_reset_calls = 0
local test_reload_calls = 0
package.loaded["typst.tests.cache_registry_reload"] = {
    reset = function()
        test_reset_calls = test_reset_calls + 1
    end,
    reload = function()
        test_reload_calls = test_reload_calls + 1
    end,
}
registry._register_for_tests({
    name = "test_reload_only",
    module = "typst.tests.cache_registry_reload",
    reset = "reset",
    reload = "reload",
    optional = true,
})
local reload_only = registry.reload()
registry._unregister_for_tests("test_reload_only")
package.loaded["typst.tests.cache_registry_reload"] = nil
assert(
    reload_only.test_reload_only == true,
    "registry reload should report test reload entry success"
)
assert(
    test_reload_calls == 1,
    "registry reload should call reload hooks when configured"
)
assert(
    test_reset_calls == 0,
    "registry reload should not call reset for reload-only entries"
)

package.loaded["typst.tests.cache_registry_unloaded_forget"] = nil
registry._register_for_tests({
    name = "test_unloaded_forget",
    module = "typst.tests.cache_registry_unloaded_forget",
    forget = "forget",
    forget_args = "bufnr",
})
local unloaded_forget = registry.forget_buffer(vim.api.nvim_get_current_buf())
registry._unregister_for_tests("test_unloaded_forget")
assert(
    unloaded_forget.test_unloaded_forget == false,
    "registry forget should skip unloaded modules"
)
assert(
    package.loaded["typst.tests.cache_registry_unloaded_forget"] == nil,
    "registry forget should not force-load unloaded modules"
)

require("typst.project.attachments")
require("typst.syntax")

local bufnr = vim.api.nvim_get_current_buf()
local forgot = registry.forget_buffer(bufnr)
assert(
    forgot.project_attachments == true,
    "registry buffer forget should clear project attachment state"
)
assert(
    forgot.treesitter == true,
    "registry buffer forget should clear treesitter"
)
assert(forgot.conceal == true, "registry buffer forget should clear conceal")
local detached = registry.detach_buffer(bufnr)
assert(detached.syntax == true, "registry buffer detach should clear syntax")
local window_forgot = registry.forget_window(vim.api.nvim_get_current_win())
assert(
    window_forgot.conceal ~= nil,
    "registry window forget should call registered window cleanup"
)

local reset = registry.reset({ retain_projects = true })
assert(reset.state == true, "registry reset should clear persisted state cache")
assert(
    reset.outputs ~= true,
    "retain-project reset should not clear output leases"
)

local original_indent = package.loaded["typst.edit.indent"]
package.loaded["typst.edit.indent"] = {
    reset = function()
        error("indent reset failed")
    end,
}
log.clear()
local guarded = registry.reset({ retain_projects = true })
package.loaded["typst.edit.indent"] = original_indent
assert(
    guarded.indent == false,
    "registry should report a failing cache entry without aborting reset"
)
local saw_failure = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "cache registry entry failed"
        and entry.fields
        and entry.fields.name == "indent"
    then
        saw_failure = true
        break
    end
end
assert(saw_failure, "registry should log cache entry reset failures")

vim.cmd("qa!")
