local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local fanout = require("typst.compiler.fanout")
local quickfix_api = require("typst.diagnostics.quickfix")
local services = require("typst.project.services")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("diagnostics-source-isolation-output"),
    diagnostics = {
        enabled = true,
        use_quickfix = true,
    },
})
local fixture_dir = typst_test_cache_path("diagnostics-source-isolation")
vim.fn.mkdir(fixture_dir, "p")
local main = fixture_dir .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()

local project = {
    key = "diagnostics-source-isolation",
    root = fixture_dir,
    main = main,
    services = services.new_state(),
}

diagnostics.publish_by_buffer(project, {
    [bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "compiler diagnostic",
            severity = vim.diagnostic.severity.ERROR,
        },
    },
}, { source = "compiler" })
diagnostics.publish_by_buffer(project, {
    [bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint diagnostic",
            severity = vim.diagnostic.severity.WARN,
        },
    },
}, { source = "lint" })
local lint_quickfix = vim.fn.getqflist({ items = 1 })
assert(
    #lint_quickfix.items == 1
        and lint_quickfix.items[1].text == "lint diagnostic",
    "lint diagnostics should own the quickfix list before compiler fanout"
)

fanout.compile_succeeded(
    project,
    { code = 0 },
    { output = fixture_dir .. "/main.pdf" }
)

assert(#vim.diagnostic.get(bufnr, {
    namespace = diagnostics.namespace_for(project, "compiler"),
}) == 0, "compiler fanout success should clear compiler diagnostics")
assert(#vim.diagnostic.get(bufnr, {
    namespace = diagnostics.namespace_for(project, "lint"),
}) == 1, "compiler fanout success should not clear lint diagnostics")

local after_compiler_clear = vim.fn.getqflist({ items = 1 })
assert(
    #after_compiler_clear.items == 1
        and after_compiler_clear.items[1].text == "lint diagnostic",
    "compiler diagnostic clear should not clear a lint-owned quickfix list"
)

diagnostics.clear(project, { source = "lint" })
assert(
    #vim.fn.getqflist() == 0,
    "clearing lint diagnostics should clear the lint-owned quickfix list"
)

quickfix_api.set(project, {
    [bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint loclist diagnostic",
            severity = vim.diagnostic.severity.WARN,
        },
    },
}, {
    list = "loclist",
    winid = vim.api.nvim_get_current_win(),
    source = "lint",
})
quickfix_api.clear(project, { source = "compiler" })
local loclist = vim.fn.getloclist(vim.api.nvim_get_current_win(), {
    items = 1,
})
assert(
    #loclist.items == 1 and loclist.items[1].text == "lint loclist diagnostic",
    "compiler clears should not clear a lint-owned location list"
)

quickfix_api.clear(project, { source = "lint" })
loclist = vim.fn.getloclist(vim.api.nvim_get_current_win(), { items = 1 })
assert(
    #loclist.items == 0,
    "clearing lint ownership should clear a lint-owned location list"
)

vim.cmd("qa!")
