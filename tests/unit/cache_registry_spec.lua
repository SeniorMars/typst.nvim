local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local registry = require("typst.core.cache_registry")

local status = registry.status()
assert(#status.entries > 0, "cache registry should expose registered entries")
local stats = registry.stats()
assert(stats.total == #status.entries, "cache stats should count entries")
assert(stats.loaded == #status.loaded, "cache stats should count loaded")
assert(stats.unloaded == #status.unloaded, "cache stats should count unloaded")
assert(stats.reset > 0, "cache stats should count reset-capable entries")
assert(stats.clear > 0, "cache stats should count clear-capable entries")
assert(stats.reload > 0, "cache stats should count reload-capable entries")
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
}) do
    assert(by_name[name], ("cache registry missing %s entry"):format(name))
end

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
assert(reloaded.conceal == true, "registry reload should refresh conceal")

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
