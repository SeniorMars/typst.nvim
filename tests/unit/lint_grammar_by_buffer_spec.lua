local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local lint_results = require("typst.lint.results")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lint-grammar-by-buffer-output"),
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)

local lint_diag = {
    lnum = 0,
    col = 0,
    message = "lint provider diagnostic",
    severity = vim.diagnostic.severity.WARN,
}
local lint_result = lint_results.normalize_provider_result(project, {
    by_buffer = {
        [bufnr] = { lint_diag },
    },
}, {
    open = true,
}, "by-buffer-lint")

assert(lint_result.ok == true, "lint by_buffer result should be ok")
assert(lint_result.published == true, "lint by_buffer result should publish")
assert(lint_result.diagnostics == 1, "lint by_buffer result should count")
assert(#vim.diagnostic.get(bufnr, {
    namespace = diagnostics.namespace_for(project, "lint"),
}) == 1, "lint by_buffer diagnostics should be visible in vim.diagnostic")
assert(
    vim.fn.getqflist({ items = 1 }).items[1].text == "lint provider diagnostic",
    "lint by_buffer diagnostics should populate quickfix when open=true"
)

local grammar_diag = {
    lnum = 0,
    col = 1,
    message = "grammar provider diagnostic",
    severity = vim.diagnostic.severity.INFO,
}
local grammar_result = typst.tools.grammar({
    bufnr = bufnr,
    open = false,
    provider = {
        name = "by-buffer-grammar",
        grammar = function()
            return {
                by_buffer = {
                    [bufnr] = { grammar_diag },
                },
            }
        end,
    },
})
assert(grammar_result.ok == true, "grammar by_buffer result should be ok")
assert(
    grammar_result.published == true,
    "grammar by_buffer result should publish"
)
assert(grammar_result.diagnostics == 1, "grammar by_buffer result should count")
local grammar_diagnostics = vim.diagnostic.get(bufnr, {
    namespace = diagnostics.namespace_for(project, "typst grammar"),
})
assert(
    #grammar_diagnostics == 1,
    "grammar by_buffer diagnostics should be visible in vim.diagnostic"
)
assert(
    grammar_diagnostics[1].message == "grammar provider diagnostic",
    "grammar by_buffer diagnostic message should survive publishing"
)

vim.cmd("qa!")
