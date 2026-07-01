local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local typst = require("typst")
local util = require("typst.core.util")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(vim.cmd, "silent! %bwipeout!")
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
        "leaf buffer should attach through import scan"
    )
    assert(
        util.same_path(project.main, main),
        "large import scan should resolve the importing main"
    )
    assert(
        project.resolutions[bufnr].main_source == "import scan",
        "project attach should record import-scan main source"
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
        "leaf buffer should reattach through cached import scan"
    )
    assert(
        util.same_path(cached_project.main, main),
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
        "leaf buffer should still attach when import scan is entry-capped"
    )
    assert(
        util.same_path(capped_project.main, capped_leaf),
        "entry-capped import scan should fall back to the leaf file"
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
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
