local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local main_file = require("typst.project.main_file")

local bufnr = vim.api.nvim_create_buf(false, true)
local buffer_path = typst_test_cache_path("buffer-main-unreadable/chapter.typ")
local missing_main = typst_test_cache_path("buffer-main-unreadable/missing.typ")
vim.fn.mkdir(vim.fn.fnamemodify(buffer_path, ":h"), "p")
vim.fn.writefile({ "= Chapter" }, buffer_path)
vim.api.nvim_buf_set_name(bufnr, buffer_path)
vim.b[bufnr].typst_main = missing_main

local main, source = main_file.discard_unreadable(
    bufnr,
    buffer_path,
    missing_main,
    "buffer variable vim.b.typst_main"
)

assert(
    main == nil and source == nil,
    "unreadable buffer main should be ignored"
)
assert(
    vim.b[bufnr].typst_main == missing_main,
    "unreadable buffer-local Typst main should not be deleted"
)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.cmd("qa!")
