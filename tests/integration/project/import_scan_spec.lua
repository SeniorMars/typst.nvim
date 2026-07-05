local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local registry = require("typst.project")
local typst = require("typst")
local util = require("typst.core.util")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

cleanup()
root_discovery._clear_import_scan_cache()

local ok, err = xpcall(function()
    local project_root = typst_test_cache_path("large-import-scan")
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root .. "/chapters", "p")

    local main = util.normalize(project_root .. "/main.typ")
    local leaf = util.normalize(project_root .. "/chapters/leaf.typ")
    vim.fn.writefile({
        "= Large Import Scan",
        '#include "chapters/leaf.typ"',
    }, main)
    vim.fn.writefile({ "= Leaf", "Leaf body." }, leaf)
    for index = 1, 230 do
        vim.fn.writefile(
            { ("= Extra %03d"):format(index) },
            ("%s/extra-%03d.typ"):format(project_root, index)
        )
    end

    typst.setup({
        root_markers = {},
        output_dir = typst_test_cache_path("large-import-scan-output"),
        project = {
            import_scan = true,
            import_scan_max_depth = 1,
            import_scan_max_files = 260,
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(leaf))
    vim.bo.filetype = "typst"
    local bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)
    root_discovery._clear_import_scan_cache()
    local project = assert(
        typst.project.attach(bufnr),
        "leaf buffer should attach before deferred import scan"
    )
    assert(
        util.same_path(project.main, leaf),
        "initial attach should use the fast fallback before import scan"
    )
    assert(
        project.resolution_pending == "import_scan",
        "initial attach should mark deferred import-scan resolution"
    )
    assert(
        project.resolutions[bufnr].resolution_pending == "import_scan",
        "buffer resolution should record pending import scan"
    )
    local initial_stats = root_discovery._import_scan_stats()
    assert(initial_stats.scans == 0, "attach should not run import scan inline")

    local resolved = vim.wait(1000, function()
        local current = registry.get(bufnr)
        return current ~= nil and util.same_path(current.main, main)
    end, 10)
    assert(resolved, "deferred import scan should resolve the importing main")
    project = assert(registry.get(bufnr), "deferred scan should keep project")
    assert(
        project.resolutions[bufnr].main_source == "import scan",
        "deferred project attach should record import-scan main source"
    )
    assert(
        project.resolution_pending == nil,
        "deferred import scan should clear project pending state"
    )
    local first_stats = root_discovery._import_scan_stats()
    assert(first_stats.scans == 1, "first attach should run import scan")
    assert(
        first_stats.files >= 200,
        "large import scan should traverse the generated fixture set"
    )
    assert(first_stats.reads >= 200, "large import scan should read candidates")

    typst.project.detach(bufnr)
    local cached_project = assert(
        typst.project.attach(bufnr),
        "leaf buffer should reattach before cached import scan"
    )
    assert(
        util.same_path(cached_project.main, leaf),
        "cached reattach should still start with the fast fallback"
    )
    resolved = vim.wait(1000, function()
        local current = registry.get(bufnr)
        return current ~= nil and util.same_path(current.main, main)
    end, 10)
    assert(
        resolved,
        "cached deferred import scan should resolve the importing main"
    )
    local cached_resolved_project =
        assert(registry.get(bufnr), "cached deferred scan should keep project")
    assert(
        util.same_path(cached_resolved_project.main, main),
        "cached large import scan should resolve the same main"
    )
    local second_stats = root_discovery._import_scan_stats()
    assert(
        second_stats.cache_hits == 1,
        "reattach should use cached import scan result"
    )
    assert(
        second_stats.scans == first_stats.scans,
        "cached reattach should not rescan large project"
    )
    assert(
        second_stats.reads == first_stats.reads,
        "cached reattach should not reread candidates"
    )

    cleanup()
    root_discovery._clear_import_scan_cache()
    local capped_root = typst_test_cache_path("large-import-scan-capped")
    vim.fn.delete(capped_root, "rf")
    vim.fn.mkdir(capped_root .. "/chapters", "p")
    local capped_main = util.normalize(capped_root .. "/main.typ")
    local capped_leaf = util.normalize(capped_root .. "/chapters/leaf.typ")
    vim.fn.writefile({
        "= Capped Import Scan",
        '#include "chapters/leaf.typ"',
    }, capped_main)
    vim.fn.writefile({ "= Leaf", "Leaf body." }, capped_leaf)
    for index = 1, 40 do
        vim.fn.writefile(
            { ("= Extra %03d"):format(index) },
            ("%s/extra-%03d.typ"):format(capped_root, index)
        )
    end

    typst.setup({
        root_markers = {},
        output_dir = typst_test_cache_path("large-import-scan-capped-output"),
        project = {
            import_scan = true,
            import_scan_max_depth = 1,
            import_scan_max_files = 260,
            import_scan_max_entries = 12,
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(capped_leaf))
    vim.bo.filetype = "typst"
    bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)
    local capped_project = assert(
        typst.project.attach(bufnr),
        "leaf buffer should attach before entry-capped import scan"
    )
    assert(
        util.same_path(capped_project.main, capped_leaf),
        "initial entry-capped attach should use the leaf fallback"
    )
    assert(
        capped_project.resolution_pending == "import_scan",
        "entry-capped scan should still be deferred from attach"
    )
    local capped_finished = vim.wait(1000, function()
        local current = registry.get(bufnr)
        return current ~= nil and current.resolution_pending == nil
    end, 10)
    assert(capped_finished, "entry-capped deferred scan should settle")
    capped_project =
        assert(registry.get(bufnr), "entry-capped attach should keep project")
    assert(
        util.same_path(capped_project.main, capped_leaf),
        "entry-capped import scan should leave the leaf fallback in place"
    )
    assert(
        capped_project.resolutions[bufnr].main_source ~= "import scan",
        "entry-capped attach should not report import scan as the main source"
    )
    local capped_stats = root_discovery._import_scan_stats()
    assert(
        capped_stats.skipped_roots == 1,
        "entry-capped attach should record one skipped scan root"
    )
    assert(
        capped_stats.reads == 0,
        "entry-capped attach should not read candidate Typst files"
    )

    cleanup()
    root_discovery._clear_import_scan_cache()
    local skipped_root = typst_test_cache_path("large-import-scan-skips")
    vim.fn.delete(skipped_root, "rf")
    vim.fn.mkdir(skipped_root .. "/chapters", "p")
    vim.fn.mkdir(skipped_root .. "/heavy", "p")
    local skipped_main = util.normalize(skipped_root .. "/main.typ")
    local skipped_leaf = util.normalize(skipped_root .. "/chapters/leaf.typ")
    vim.fn.writefile({
        "= Skipped Import Scan",
        '#include "chapters/leaf.typ"',
    }, skipped_main)
    vim.fn.writefile({ "= Leaf", "Leaf body." }, skipped_leaf)
    for index = 1, 80 do
        vim.fn.writefile(
            { ("= Heavy %03d"):format(index) },
            ("%s/heavy/generated-%03d.typ"):format(skipped_root, index)
        )
    end

    typst.setup({
        root_markers = {},
        output_dir = typst_test_cache_path("large-import-scan-skips-output"),
        project = {
            import_scan = true,
            import_scan_max_depth = 1,
            import_scan_max_files = 260,
            import_scan_max_entries = 16,
            import_scan_skip_dirs = { "heavy" },
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(skipped_leaf))
    vim.bo.filetype = "typst"
    bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)
    local skipped_project = assert(
        typst.project.attach(bufnr),
        "leaf buffer should attach before skip-dir import scan"
    )
    assert(
        util.same_path(skipped_project.main, skipped_leaf),
        "skip-dir attach should start with the leaf fallback"
    )
    local skipped_resolved = vim.wait(1000, function()
        local current = registry.get(bufnr)
        return current ~= nil and util.same_path(current.main, skipped_main)
    end, 10)
    assert(
        skipped_resolved,
        "configured import-scan skip dirs should preserve entry budget for the real main"
    )
    local skipped_stats = root_discovery._import_scan_stats()
    assert(
        skipped_stats.last_hit_entry_limit == false,
        "skip-dir import scan should not hit the entry cap"
    )

    root_discovery._clear_import_scan_cache()
    local direct_scan_opts = {
        project = {
            import_scan = true,
            import_scan_max_depth = 1,
            import_scan_max_files = 260,
            import_scan_max_entries = 16,
            import_scan_skip_dirs = { "heavy", "generated" },
        },
    }
    local direct_main = root_discovery.import_scan_main(
        skipped_leaf,
        util.dirname(skipped_leaf),
        "buffer directory",
        direct_scan_opts
    )
    assert(
        util.same_path(direct_main, skipped_main),
        "direct import scan should resolve the skipped-dir fixture"
    )
    local direct_stats = root_discovery._import_scan_stats()
    direct_scan_opts.project.import_scan_skip_dirs = { "generated", "heavy" }
    local cached_main = root_discovery.import_scan_main(
        skipped_leaf,
        util.dirname(skipped_leaf),
        "buffer directory",
        direct_scan_opts
    )
    local cached_stats = root_discovery._import_scan_stats()
    assert(
        util.same_path(cached_main, skipped_main),
        "reordered skip dirs should preserve the same import-scan result"
    )
    assert(
        cached_stats.cache_hits == direct_stats.cache_hits + 1,
        "import-scan cache keys should not depend on skip-dir order"
    )
    assert(
        cached_stats.scans == direct_stats.scans,
        "reordered skip dirs should reuse the cached import-scan result"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
