local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local matches = require("typst.conceal.matches")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, typst_test_cache_path("conceal-parser.typ"))
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "$ alpha + beta $",
    "#let x = 1",
})
vim.bo[bufnr].filetype = "typst"

local parser_ok = pcall(vim.treesitter.get_parser, bufnr, "typst")
if not parser_ok then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.cmd("qa!")
    return
end

matches.matches(bufnr, { start_row = 0, end_row = 2 })
local first = matches._parser_registration_count()
assert(first >= 1, "conceal matches should register parser callbacks")

matches.reset()
matches.matches(bufnr, { start_row = 0, end_row = 2 })
local second = matches._parser_registration_count()
assert(
    second == first,
    "reset/re-enable should not duplicate parser callback registrations"
)

matches.forget(bufnr)
matches.matches(bufnr, { start_row = 0, end_row = 2 })
local third = matches._parser_registration_count()
assert(
    third == first,
    "buffer forget on a live parser should keep the stable registration guard"
)

vim.api.nvim_buf_delete(bufnr, { force = true })
matches.forget(bufnr)
assert(
    matches._parser_registration_count() == 0,
    "invalid buffer forget should clear parser registration tracking"
)

vim.cmd("qa!")
