local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local quickfix = require("typst.diagnostics.quickfix")
local services = require("typst.project.services")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("quickfix-nil-project-clear-output"),
    diagnostics = {
        enabled = true,
        use_quickfix = true,
    },
})
local fixture_dir = typst_test_cache_path("quickfix-nil-project-clear")
vim.fn.mkdir(fixture_dir, "p")
local main = fixture_dir .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local winid = vim.api.nvim_get_current_win()

local project = {
    key = "quickfix-nil-project-clear",
    root = fixture_dir,
    main = main,
    services = services.new_state(),
}

diagnostics.publish_by_buffer(project, {
    [bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "lint quickfix",
            severity = vim.diagnostic.severity.WARN,
        },
    },
}, { source = "lint" })
local quickfix_items = vim.fn.getqflist({ items = 1 }).items
assert(#quickfix_items == 1, "lint quickfix should start populated")
assert(
    quickfix.clear(nil, { source = "lint" }) == false,
    "nil-project quickfix clears should require force or reset"
)
quickfix_items = vim.fn.getqflist({ items = 1 }).items
assert(
    #quickfix_items == 1,
    "nil-project quickfix clear should not clear owned project lists"
)

quickfix.open(project, diagnostics.namespace_for(project, "lint"), {
    list = "loclist",
    winid = winid,
    open = false,
})
local loclist_items = vim.fn.getloclist(winid, { items = 1 }).items
assert(#loclist_items == 1, "lint loclist should start populated")
assert(quickfix.clear(nil, {
    source = "lint",
    list = "loclist",
    winid = winid,
}) == false, "nil-project loclist clears should require force or reset")
loclist_items = vim.fn.getloclist(winid, { items = 1 }).items
assert(
    #loclist_items == 1,
    "nil-project loclist clear should not clear owned project loclists"
)

assert(
    quickfix.clear(nil, { source = "lint", force = true }) == true,
    "force nil-project clears should remain available for reset-style cleanup"
)
assert(
    #vim.fn.getqflist() == 0,
    "forced nil-project clear should clear quickfix"
)
assert(
    #vim.fn.getloclist(winid) == 0,
    "forced nil-project clear should clear owned loclists"
)

vim.cmd("qa!")
