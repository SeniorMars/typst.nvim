local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project = require("typst.project")

typst.reset({ force = true })
typst.setup({})

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = ""

local before = vim.tbl_count(project.all())
local capabilities = typst.viewer.capabilities({ bufnr = bufnr })
local after = vim.tbl_count(project.all())

assert(type(capabilities) == "table", "viewer capabilities should return table")
assert(
    after == before,
    "viewer capabilities should not resolve or attach a Typst project"
)
