local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")

local fixture = typst_test_cache_path("import-scan-stats")
vim.fn.delete(fixture, "rf")
vim.fn.mkdir(fixture .. "/nested", "p")

local main = fixture .. "/main.typ"
local chapter = fixture .. "/nested/chapter.typ"
vim.fn.writefile({ '#include "nested/chapter.typ"', "" }, main)
vim.fn.writefile({ "= Chapter" }, chapter)

root_discovery._clear_import_scan_cache()
local found, source, scan_root, scan_source = root_discovery.import_scan_main(
    chapter,
    fixture,
    "buffer directory",
    {
        project = {
            import_scan = true,
            import_scan_max_files = 20,
            import_scan_max_entries = 100,
            import_scan_max_descendant_depth = 2,
            import_scan_skip_dirs = {},
        },
    },
    { mode = "unit" }
)

assert(found == main, "import scan should resolve the importing main")
assert(source == "import scan", "import scan should report main source")
assert(scan_root == fixture, "import scan should report scan root")
assert(
    scan_source == "import scan root",
    "import scan should report root source"
)

local stats = root_discovery._import_scan_stats()
assert(stats.attempts == 1, "import scan should count attempts")
assert(stats.scans == 1, "import scan should count real scans")
assert((stats.dirs or 0) >= 1, "import scan should count directories")
assert((stats.files or 0) >= 2, "import scan should count Typst files")
assert((stats.reads or 0) >= 1, "import scan should count file reads")
assert(stats.last_mode == "unit", "import scan should record mode")
assert(stats.last_root == fixture, "import scan should record root")
assert(stats.last_max_files == 20, "import scan should record file budget")
assert(stats.last_max_entries == 100, "import scan should record entry budget")
assert(stats.last_abort_reason == nil, "successful scan should not abort")

local summary = root_discovery.import_scan_stats_summary(stats)
assert(summary:find("dirs=", 1, true), "summary should include dirs")
assert(summary:find("mode=unit", 1, true), "summary should include mode")
assert(summary:find("abort=none", 1, true), "summary should include abort")

root_discovery._clear_import_scan_cache()
local first_limited = root_discovery.import_scan_main_async(
    chapter,
    fixture,
    "buffer directory",
    {
        project = {
            import_scan = true,
            import_scan_max_files = 20,
            import_scan_max_entries = 1,
            import_scan_max_descendant_depth = 2,
            import_scan_skip_dirs = {},
        },
    },
    { mode = "unit-async", delay_ms = 0, entry_budget = 8 }
)
assert(first_limited, "limited async import scan should return a handle")
assert(
    vim.wait(1000, function()
        return first_limited.pending ~= true
    end),
    "limited async import scan should settle"
)
assert(
    first_limited.result.status == "entry_limit",
    "limited async import scan should expose entry-limit status"
)
local first_limited_stats = root_discovery._import_scan_stats()
assert(
    first_limited_stats.cache_hits == 0,
    "first limited scan should not hit cache"
)

local second_limited = root_discovery.import_scan_main_async(
    chapter,
    fixture,
    "buffer directory",
    {
        project = {
            import_scan = true,
            import_scan_max_files = 20,
            import_scan_max_entries = 1,
            import_scan_max_descendant_depth = 2,
            import_scan_skip_dirs = {},
        },
    },
    { mode = "unit-async", delay_ms = 0, entry_budget = 8 }
)
assert(
    second_limited,
    "second limited async import scan should return a handle"
)
assert(
    vim.wait(1000, function()
        return second_limited.pending ~= true
    end),
    "second limited async import scan should settle"
)
local second_limited_stats = root_discovery._import_scan_stats()
assert(
    second_limited_stats.cache_hits == 0,
    "aborted async import scans should not be cached as not_found"
)
assert(
    second_limited_stats.scans == 2,
    "aborted async import scans should run again instead of replaying cache"
)
assert(
    second_limited.result.status == "entry_limit",
    "second limited async import scan should preserve abort status"
)

vim.fn.delete(fixture, "rf")
vim.cmd("qa!")
