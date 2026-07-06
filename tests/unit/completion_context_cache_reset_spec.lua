local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local completion = require("typst.completion")
local context = require("typst.completion.context")
local cache_registry = require("typst.core.cache_registry")

local bufnr = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

local kind = context.kind(bufnr, { 0, 5 }, {})
assert(kind ~= nil, "completion context should classify the buffer")
assert(
    context._cache_has_for_tests(bufnr),
    "completion context should cache the classified buffer"
)

completion.reset()
assert(
    not context._cache_has_for_tests(bufnr),
    "completion.reset should clear completion context cache"
)

context.kind(bufnr, { 0, 5 }, {})
assert(context._cache_has_for_tests(bufnr), "cache should refill after reset")

cache_registry.forget_buffer(bufnr)
assert(
    not context._cache_has_for_tests(bufnr),
    "cache_registry.forget_buffer should clear completion context cache"
)

vim.cmd("qa!")
