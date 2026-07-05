local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local quickfix = require("typst.diagnostics.quickfix")
local services = require("typst.project.services")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("diagnostics-qf-source-rebuild-output"),
    diagnostics = {
        enabled = true,
        use_quickfix = true,
    },
})
local fixture_dir = typst_test_cache_path("diagnostics-qf-source-rebuild")
vim.fn.mkdir(fixture_dir, "p")
local first = fixture_dir .. "/first.typ"
local second = fixture_dir .. "/second.typ"
vim.fn.writefile({ "= First" }, first)
vim.fn.writefile({ "= Second" }, second)

vim.cmd.edit(first)
local first_bufnr = vim.api.nvim_get_current_buf()
vim.cmd.edit(second)
local second_bufnr = vim.api.nvim_get_current_buf()

local project = {
    key = "diagnostics-qf-source-rebuild",
    root = fixture_dir,
    main = first,
    services = services.new_state(),
}

diagnostics.publish_by_buffer(project, {
    [first_bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint first",
            severity = vim.diagnostic.severity.WARN,
        },
    },
    [second_bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint second",
            severity = vim.diagnostic.severity.WARN,
        },
    },
}, { source = "lint" })
local items = vim.fn.getqflist({ items = 1 }).items
assert(#items == 2, "lint quickfix should start with two buffer items")

diagnostics.clear_buffer(project, first_bufnr, { source = "lint" })
items = vim.fn.getqflist({ items = 1 }).items
assert(
    #items == 1,
    "source-owned quickfix should be rebuilt after buffer clear"
)
assert(
    items[1].text == "lint second",
    "rebuilt quickfix should drop stale buffer item"
)

diagnostics.publish_by_buffer(project, {
    [first_bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint opened",
            severity = vim.diagnostic.severity.WARN,
        },
    },
}, { source = "lint" })
vim.fn.setqflist({}, "r", { title = "user list", items = {} })
quickfix.open(project, diagnostics.namespace_for(project, "lint"), {
    open = false,
})
items = vim.fn.getqflist({ items = 1 }).items
assert(
    #items == 1 and items[1].text == "lint opened",
    "quickfix.open should populate lint diagnostics"
)

diagnostics.clear(project, { source = "compiler" })
items = vim.fn.getqflist({ items = 1 }).items
assert(
    #items == 1 and items[1].text == "lint opened",
    "compiler clear should not clear a lint-opened quickfix without explicit source opts"
)

diagnostics.clear(project, { source = "lint" })
assert(#vim.fn.getqflist() == 0, "lint clear should clear lint-opened quickfix")

vim.cmd("qa!")
