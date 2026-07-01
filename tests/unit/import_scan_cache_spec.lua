local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local util = require("typst.core.util")

root_discovery._clear_import_scan_cache()

local workdir = typst_test_cache_path("import-scan-cache")
vim.fn.delete(workdir, "rf")
vim.fn.mkdir(workdir, "p")

local main = util.normalize(workdir .. "/main.typ")
local leaf = util.normalize(workdir .. "/leaf.typ")
vim.fn.writefile({ '#include "leaf.typ"', "= Main" }, main)
vim.fn.writefile({ "= Leaf" }, leaf)
for index = 1, 25 do
    vim.fn.writefile(
        { ("= Extra %d"):format(index) },
        workdir .. "/extra-" .. index .. ".typ"
    )
end

local opts = {
    project = {
        import_scan = true,
        import_scan_max_files = 50,
        import_scan_max_depth = 0,
    },
}

local resolved =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", opts)
assert(util.same_path(resolved, main), "first import scan should find main")
local first_stats = root_discovery._import_scan_stats()
assert(first_stats.scans == 1, "first import scan should walk candidates")
assert(first_stats.reads > 0, "first import scan should read candidates")

local cached =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", opts)
assert(util.same_path(cached, main), "cached import scan should find main")
local second_stats = root_discovery._import_scan_stats()
assert(second_stats.cache_hits == 1, "second import scan should hit cache")
assert(
    second_stats.scans == first_stats.scans,
    "cached import scan should not walk candidates again"
)
assert(
    second_stats.reads == first_stats.reads,
    "cached import scan should not reread candidates"
)

local cleared = require("typst.core.cache_registry").clear()
assert(cleared.import_scan, "cache registry should clear import-scan cache")
local after_clear =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", opts)
assert(util.same_path(after_clear, main), "import scan should still resolve")
local after_clear_stats = root_discovery._import_scan_stats()
assert(
    after_clear_stats.scans == 1 and after_clear_stats.cache_hits == 0,
    "cache clear should force the next import scan to walk candidates"
)

root_discovery._clear_import_scan_cache()
local capped_workdir = typst_test_cache_path("import-scan-entry-cap")
vim.fn.delete(capped_workdir, "rf")
vim.fn.mkdir(capped_workdir .. "/nested", "p")
local capped_main = util.normalize(capped_workdir .. "/main.typ")
local capped_leaf = util.normalize(capped_workdir .. "/nested/leaf.typ")
vim.fn.writefile({ '#include "nested/leaf.typ"', "= Main" }, capped_main)
vim.fn.writefile({ "= Leaf" }, capped_leaf)
for index = 1, 30 do
    vim.fn.writefile(
        { ("= Extra %d"):format(index) },
        capped_workdir .. "/extra-" .. index .. ".typ"
    )
end

local capped_opts = {
    project = {
        import_scan = true,
        import_scan_max_files = 50,
        import_scan_max_depth = 0,
        import_scan_max_entries = 10,
    },
}

local capped = root_discovery.import_scan_main(
    capped_leaf,
    capped_workdir,
    "buffer directory",
    capped_opts
)
assert(capped == nil, "entry-capped import scan should not use partial roots")
local capped_stats = root_discovery._import_scan_stats()
assert(
    capped_stats.skipped_roots == 1,
    "entry-capped import scan should record the abandoned scan root"
)
assert(
    capped_stats.last_hit_entry_limit == true,
    "entry-capped import scan should record the entry cap"
)
assert(
    capped_stats.reads == 0,
    "entry-capped import scan should skip candidate file reads"
)

local cached_capped = root_discovery.import_scan_main(
    capped_leaf,
    capped_workdir,
    "buffer directory",
    capped_opts
)
assert(cached_capped == nil, "cached entry-capped import scan should stay nil")
local cached_capped_stats = root_discovery._import_scan_stats()
assert(
    cached_capped_stats.cache_hits == 1,
    "entry-capped nil import scan should be cached"
)
assert(
    cached_capped_stats.scans == capped_stats.scans,
    "cached entry-capped import scan should not rescan"
)

root_discovery._clear_import_scan_cache()
local helper_cap_workdir = typst_test_cache_path("import-scan-helper-entry-cap")
vim.fn.delete(helper_cap_workdir, "rf")
vim.fn.mkdir(helper_cap_workdir, "p")
local helper_cap_main = util.normalize(helper_cap_workdir .. "/aaa-main.typ")
local helper_cap_leaf = util.normalize(helper_cap_workdir .. "/bbb-leaf.typ")
vim.fn.writefile({ '#include "bbb-leaf.typ"', "= Main" }, helper_cap_main)
vim.fn.writefile({ "= Leaf" }, helper_cap_leaf)
for index = 1, 12 do
    vim.fn.writefile(
        { "not typst" },
        ("%s/ccc-%02d.txt"):format(helper_cap_workdir, index)
    )
end
vim.fn.writefile({ "= Extra" }, helper_cap_workdir .. "/zzz-extra.typ")

local helper_cap_opts = {
    project = {
        import_scan = true,
        import_scan_max_files = 2,
        import_scan_max_depth = 0,
        import_scan_max_entries = 6,
    },
}

local helper_capped = root_discovery.import_scan_main(
    helper_cap_leaf,
    helper_cap_workdir,
    "buffer directory",
    helper_cap_opts
)
assert(
    helper_capped == nil,
    "remaining-candidate probe should respect the entry cap"
)
local helper_capped_stats = root_discovery._import_scan_stats()
assert(
    helper_capped_stats.skipped_roots == 1,
    "remaining-candidate probe should skip roots that exceed the entry cap"
)
assert(
    helper_capped_stats.last_hit_entry_limit == true,
    "remaining-candidate probe should report entry-cap exhaustion"
)
assert(
    helper_capped_stats.reads == 0,
    "entry-capped remaining-candidate probe should avoid candidate reads"
)

vim.cmd("qa!")
