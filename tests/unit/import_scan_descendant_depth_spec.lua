local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local util = require("typst.core.util")

root_discovery._clear_import_scan_cache()

local workdir = typst_test_cache_path("import-scan-descendant-depth")
vim.fn.delete(workdir, "rf")
vim.fn.mkdir(workdir .. "/level1/level2", "p")

local leaf = util.normalize(workdir .. "/level1/level2/leaf.typ")
local deep_main = util.normalize(workdir .. "/level1/level2/main.typ")
vim.fn.writefile({ "= Leaf" }, leaf)
vim.fn.writefile({ "= Main", '#include "leaf.typ"' }, deep_main)

local shallow =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", {
        project = {
            import_scan = true,
            import_scan_max_files = 20,
            import_scan_max_depth = 0,
            import_scan_max_descendant_depth = 1,
            import_scan_max_entries = 100,
            import_scan_skip_dirs = {},
        },
    })
assert(
    shallow == nil,
    "descendant depth cap should prevent scanning deeper Typst mains"
)

root_discovery._clear_import_scan_cache()
local deep =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", {
        project = {
            import_scan = true,
            import_scan_max_files = 20,
            import_scan_max_depth = 0,
            import_scan_max_descendant_depth = 2,
            import_scan_max_entries = 100,
            import_scan_skip_dirs = {},
        },
    })
assert(
    util.same_path(deep, deep_main),
    "larger descendant depth should allow nested import-scan mains"
)

vim.cmd("qa!")
