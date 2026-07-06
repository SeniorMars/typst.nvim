local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
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
    local project_root = typst_test_cache_path("explain-late-import")
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root .. "/chapters", "p")

    local main = util.normalize(project_root .. "/main.typ")
    local leaf = util.normalize(project_root .. "/chapters/leaf.typ")
    local main_lines = { "= Main" }
    for index = 1, root_discovery.import_scan_line_limit() do
        main_lines[#main_lines + 1] = ("// filler %03d"):format(index)
    end
    main_lines[#main_lines + 1] = '#include "chapters/leaf.typ"'
    vim.fn.writefile(main_lines, main)
    vim.fn.writefile({ "= Leaf", "Late import fixture." }, leaf)

    typst.setup({
        root_markers = {},
        output_dir = typst_test_cache_path("explain-late-import-output"),
        project = {
            import_scan = true,
            import_scan_max_depth = 1,
            import_scan_max_files = 20,
        },
    })

    vim.cmd.edit(vim.fn.fnameescape(leaf))
    vim.bo.filetype = "typst"
    local report, lines =
        typst.ui.explain_project({ echo = false, settle_pending = true })
    assert(report and report.ok, "explain_project should return a report")
    assert(
        util.same_path(report.main, leaf),
        "late import should fall back to the current buffer"
    )
    assert(
        report.main_confidence == "low",
        "late import fallback should be reported as low confidence"
    )

    local import_scan = nil
    local project_file_stage = nil
    for _, stage in ipairs(report.stages or {}) do
        if stage.stage == "import_scan" then
            import_scan = stage
        elseif stage.stage == ".typstmain" then
            project_file_stage = stage
        end
    end
    assert(project_file_stage, "resolver trace should include .typstmain stage")
    assert(
        project_file_stage.status ~= "skipped"
            or project_file_stage.confidence == nil,
        "skipped .typstmain stages should not report confidence"
    )
    assert(import_scan, "resolver trace should include import_scan stage")
    assert(
        import_scan.status == "not_found",
        "late import should explain import scan miss"
    )

    local text = table.concat(lines or {}, "\n")
    assert(
        text:find("main confidence: low", 1, true),
        "explanation should show low confidence"
    )
    assert(
        text:find("first 500 lines", 1, true),
        "explanation should mention import-scan line limit"
    )
    assert(
        text:find(":TypstSetMain", 1, true),
        "explanation should suggest deterministic main-file configuration"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
