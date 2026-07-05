local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local quickfix = require("typst.diagnostics.quickfix")
local diagnostics_service = require("typst.project.services.diagnostics")
local project_services = require("typst.project.services")

local ns = vim.api.nvim_create_namespace("typst-loclist-window-test")
local file_a = typst_test_cache_path("loclist-window", "a.typ")
local file_b = typst_test_cache_path("loclist-window", "b.typ")
vim.fn.delete(vim.fs.dirname(file_a), "rf")
vim.fn.mkdir(vim.fs.dirname(file_a), "p")
vim.fn.writefile({ "= A" }, file_a)
vim.fn.writefile({ "= B" }, file_b)

vim.cmd.enew()
vim.cmd("edit " .. vim.fn.fnameescape(file_a))
local bufnr_a = vim.api.nvim_get_current_buf()
local win_a = vim.api.nvim_get_current_win()
vim.cmd.vsplit()
vim.cmd("edit " .. vim.fn.fnameescape(file_b))
local win_b = vim.api.nvim_get_current_win()

local project = {
    key = "loclist-window",
    root = vim.fs.dirname(file_a),
    main = file_a,
    bufs = { [bufnr_a] = true },
    services = project_services.new_state(),
}
diagnostics_service.set(project, {
    buffers = { [bufnr_a] = true },
})
vim.diagnostic.set(ns, bufnr_a, {
    {
        lnum = 0,
        col = 0,
        message = "diagnostic for A",
        severity = vim.diagnostic.severity.ERROR,
    },
})
quickfix.open(project, ns, { list = "loclist", winid = win_a })
local loc_a = vim.fn.getloclist(win_a, { items = 1, winid = 1, title = 1 })
local loc_b = vim.fn.getloclist(win_b, { items = 1, winid = 1, title = 1 })
assert(#loc_a.items == 1, "target window loclist should receive diagnostics")
assert(loc_a.winid ~= 0, "target window loclist should be open")
assert(
    #loc_b.items == 0,
    "current window loclist should not receive target diagnostics"
)
assert(loc_b.winid == 0, "current window loclist should stay closed")

vim.cmd("qa!")
