local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local lifecycle = require("typst.project.lifecycle")
local lifecycle_buffers = require("typst.project.lifecycle.buffers")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    project = {
        import_scan = false,
    },
})

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Dirty ticks" })

assert(typst.project.attach(bufnr), "buffer should attach")
vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr, modeline = false })
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "TextChanged should record a debounce tick"
)

lifecycle.detach(bufnr)
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "buffer detach should forget debounce ticks"
)

local project_dir = vim.fn.tempname()
vim.fn.mkdir(project_dir, "p")
local chapter = project_dir .. "/chapter.typ"
local main = project_dir .. "/main.typ"
vim.fn.writefile({ "= Chapter" }, chapter)
vim.fn.writefile({ "= Main", '#include "chapter.typ"' }, main)

vim.cmd.edit(vim.fn.fnameescape(chapter))
local moved_bufnr = vim.api.nvim_get_current_buf()
vim.bo[moved_bufnr].filetype = "typst"
assert(typst.project.attach(moved_bufnr), "real file buffer should attach")
vim.api.nvim_buf_set_lines(moved_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = moved_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "project transition setup should record a debounce tick"
)
lifecycle.set_main(main, moved_bufnr, { persist = false })
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "project transition should forget old project-key debounce ticks"
)

vim.cmd.enew()
local reset_bufnr = vim.api.nvim_get_current_buf()
vim.bo[reset_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(reset_bufnr, 0, -1, false, { "= Reset ticks" })
assert(typst.project.attach(reset_bufnr), "second buffer should attach")
vim.api.nvim_buf_set_lines(reset_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = reset_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "second TextChanged should record a debounce tick"
)
typst.reset({ force = true })
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "plugin reset should clear all debounce ticks"
)
