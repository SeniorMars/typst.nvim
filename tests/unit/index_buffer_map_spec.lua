local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local index = require("typst.index")
local store = require("typst.project.store")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

typst.reset()
local fixture_root = typst_test_cache_path("index-buffer-map")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
vim.fn.writefile({
    "= Main <main>",
    "See @main.",
}, main)

typst.setup({
    root = fixture_root,
    root_markers = {},
    project = {
        import_scan = false,
    },
})
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local snapshot = typst.project.set_main(main)
local project = assert(store.get(snapshot.key))

local original_loaded_buffers_by_path = util.loaded_buffers_by_path
local calls = 0
util.loaded_buffers_by_path = function(...)
    calls = calls + 1
    return original_loaded_buffers_by_path(...)
end

local collected = index.collect({ project = project })
assert(collected and #collected.headings > 0, "index collect should succeed")
assert(
    calls == 1,
    ("index collect should build one buffer map, got %d"):format(calls)
)

index.mark_dirty(project, "buffer-map-unit")
calls = 0
telemetry.reset()
local headings = index.headings({ project = project })
assert(#headings > 0, "index category fallback should collect headings")
assert(
    calls == 1,
    ("index category fallback should reuse one buffer map, got %d"):format(
        calls
    )
)
assert(
    (telemetry.snapshot()["index.collect"] or {}).count == 1,
    "index category fallback should preserve public collect telemetry"
)

util.loaded_buffers_by_path = original_loaded_buffers_by_path
vim.cmd("qa!")
