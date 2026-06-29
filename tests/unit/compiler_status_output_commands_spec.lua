local ctx = require("tests.helpers.compiler_commands").setup()
local root = ctx.root
local typst = ctx.typst
local project = ctx.project
local main = ctx.main
local main_bufnr = ctx.main_bufnr

local snapshot, status_lines = typst.ui.status_report({ echo = false })
assert(
    snapshot.attached,
    "status_report should return the attached project snapshot"
)
assert(
    status_lines[1] == "Typst:idle main.typ",
    "status_report should include the compact status"
)

local detailed, detail_lines =
    typst.ui.status_report({ detailed = true, echo = false })
assert(
    detailed.key == project.key,
    "detailed status_report should return the project snapshot"
)
assert(
    detail_lines[1] == "typst.nvim",
    "detailed status_report should include detailed project lines"
)

local snapshots, all_lines = typst.ui.status_all({ echo = false })
assert(#snapshots >= 1, "status_all should include registered projects")
assert(
    vim.tbl_contains(
        vim.tbl_map(function(snapshot)
            return snapshot.key
        end, snapshots),
        project.key
    ),
    "status_all should include the current project"
)
assert(
    all_lines[1]:find("main", 1, true),
    "status_all should include a table header"
)

local bang_snapshots, bang_lines =
    typst.ui.status_report({ bang = true, echo = false })
assert(
    #bang_snapshots >= 1,
    "bang status_report should return all project snapshots"
)
assert(
    bang_lines[1]:find("main", 1, true),
    "bang status_report should include the all-project table"
)

vim.cmd("TypstStatus")
vim.cmd("TypstStatus!")
vim.cmd("TypstStatusAll")

typst_test_compiler(project).status = "error"
typst_test_compiler(project).last_command =
    { "typst", "compile", project.main, typst_test_compiler(project).output }
typst_test_compiler(project).last_cwd = project.root
typst_test_compiler(project).last_result = {
    code = 1,
    stdout = "stdout line\n",
    stderr = "stderr line\n",
}

local _, output_lines = typst.compiler.output({ open = false })
local output_text = table.concat(output_lines, "\n")
assert(
    output_text:find("typst.nvim compiler output", 1, true),
    "compile_output should include a title"
)
assert(
    output_text:find("stdout line", 1, true),
    "compile_output should include stdout"
)
assert(
    output_text:find("stderr line", 1, true),
    "compile_output should include stderr"
)
assert(
    output_text:find("exit: 1", 1, true),
    "compile_output should include the exit code"
)

local output_buf, opened_lines = typst.compiler.output()
assert(
    vim.api.nvim_buf_is_valid(output_buf),
    "compile_output should return the opened buffer"
)
assert(
    vim.bo[output_buf].filetype == "typstoutput",
    "compile_output should open a typstoutput buffer"
)
assert(
    vim.deep_equal(output_lines, opened_lines),
    "compile_output open=false and open=true should agree"
)

vim.api.nvim_set_current_buf(main_bufnr)
vim.cmd("TypstCompileOutput")
assert(
    vim.bo[vim.api.nvim_get_current_buf()].filetype == "typstoutput",
    "TypstCompileOutput should open output"
)

local stop_summary = typst.compiler.stop_all({ notify = false })
assert(stop_summary.total >= 1, "stop_all should see the registered project")
assert(stop_summary.idle >= 1, "stop_all should count idle projects")

vim.api.nvim_set_current_buf(main_bufnr)
typst.project.set_main(main)

local diagnostics = require("typst.diagnostics")
diagnostics.publish(
    project,
    "tests/fixtures/basic/main.typ:1:1: error: command test diagnostic"
)
vim.cmd("TypstErrors")
local quickfix = vim.fn.getqflist()
assert(
    #quickfix > 0,
    "TypstErrors should populate quickfix from published diagnostics"
)
assert(
    quickfix[1].text:find("command test diagnostic", 1, true),
    "TypstErrors quickfix should include diagnostics"
)

vim.cmd("qa!")
