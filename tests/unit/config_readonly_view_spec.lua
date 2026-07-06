local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")

config.setup({
    diagnostics = {
        external_paths = "quickfix-only",
    },
})

local cfg = config.get()
assert(
    cfg.diagnostics.external_paths == "quickfix-only",
    "config.get() should still support normal indexed reads"
)

local ok, err = pcall(function()
    cfg.diagnostics.external_paths = "bufadd"
end)
assert(not ok, "config.get() nested tables should remain read-only")
assert(
    tostring(err):find("read%-only view") ~= nil,
    "read-only mutation error should explain config.get()"
)

local snapshot_seen = {}
for key in pairs(config.snapshot()) do
    snapshot_seen[key] = true
end

assert(snapshot_seen.compile, "config.snapshot() should expose top-level keys")
assert(snapshot_seen.diagnostics, "config.snapshot() should expose diagnostics")

local nested = {}
for key in pairs(config.snapshot().diagnostics) do
    nested[key] = true
end

assert(
    nested.external_paths,
    "config.snapshot().diagnostics should expose nested keys"
)

vim.cmd("qa!")
