local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local typst = require("typst")

local case_id = 0

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.fn.setqflist({}, "r")
    end)
    pcall(vim.cmd, "silent! %bwipeout!")
end

local function run_case(name, fn)
    case_id = case_id + 1
    cleanup()

    local ok, err = xpcall(fn, debug.traceback)

    cleanup()

    if not ok then
        error(("diagnostics quickfix case failed [%s]:\n%s"):format(name, err))
    end
end

local function wait_for_compile(done_ref)
    assert(
        vim.wait(10000, function()
            return done_ref.done
        end, 20),
        "Typst compile did not finish"
    )
end

run_case("TypstDiagnostics command populates owned quickfix", function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("diagnostics-command-output"),
        diagnostics = {
            enabled = true,
            use_quickfix = false,
        },
    })

    local broken = root .. "/tests/fixtures/basic/broken.typ"
    vim.cmd.edit(broken)
    local broken_bufnr = vim.api.nvim_get_current_buf()
    local project = typst.project.set_main(broken)

    local compile = { done = false }
    typst.compiler.compile({}, function(result)
        assert(
            result.code ~= 0,
            "expected compile failure before diagnostics command test"
        )
        compile.done = true
    end)
    wait_for_compile(compile)

    assert(
        #vim.fn.getqflist() == 0,
        "quickfix should not be populated automatically"
    )

    vim.cmd("TypstDiagnostics")
    local quickfix = vim.fn.getqflist()
    assert(
        #quickfix > 0,
        "TypstDiagnostics should populate quickfix from published diagnostics"
    )
    assert(
        quickfix[1].bufnr == broken_bufnr,
        "quickfix item should point to the Typst buffer"
    )

    diagnostics.clear(project)
    assert(
        #vim.fn.getqflist() == 0,
        "manual TypstDiagnostics quickfix should be cleared with diagnostics"
    )

    vim.fn.setqflist({}, "r", {
        title = "user quickfix",
        items = {
            {
                bufnr = broken_bufnr,
                lnum = 1,
                col = 1,
                text = "user item",
            },
        },
    })

    diagnostics.clear(project)
    assert(
        #vim.fn.getqflist() == 1,
        "unowned quickfix list should not be cleared"
    )
end)

run_case("clearing another project preserves owned quickfix", function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("diagnostics-qf-ownership-output"),
        diagnostics = {
            enabled = true,
            use_quickfix = true,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"

    vim.cmd.edit(main)
    local main_bufnr = vim.api.nvim_get_current_buf()
    local project_a = typst.project.set_main(main)

    vim.cmd.edit(chapter)
    local project_b = typst.project.set_main(chapter)

    diagnostics.set_quickfix(project_a, {
        [main_bufnr] = {
            {
                lnum = 0,
                col = 0,
                message = "project A diagnostic",
                severity = vim.diagnostic.severity.ERROR,
            },
        },
    })

    local before = vim.fn.getqflist({ title = 1, items = 1 })
    assert(
        before.title and before.title:match("typst%.nvim"),
        "project A quickfix should be owned by typst.nvim"
    )
    assert(#before.items == 1, "project A quickfix should contain one item")

    diagnostics.clear(project_b)

    local after = vim.fn.getqflist({ title = 1, items = 1 })
    assert(
        after.title == before.title,
        "clearing project B diagnostics should not replace project A quickfix"
    )
    assert(
        #after.items == 1,
        "clearing project B diagnostics should not clear project A quickfix items"
    )
    assert(
        after.items[1].text == "project A diagnostic",
        "project A quickfix item should survive project B clear"
    )
end)

vim.cmd("qa!")
