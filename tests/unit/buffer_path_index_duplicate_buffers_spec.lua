local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local buffer = require("typst.core.buffer")
local path_util = require("typst.core.path")

buffer.reset()

local path = typst_test_cache_path("buffer-path-index-duplicates/main.typ")
vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
assert(vim.fn.writefile({ "= Duplicate" }, path) == 0, "write fixture")

local first = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(first, 0, -1, false, { "= Duplicate A" })
local second = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(second, 0, -1, false, { "= Duplicate B" })
local by_path = {
    [path_util.path_key(path)] = {
        [first] = true,
        [second] = true,
    },
}

assert(first ~= second, "test should create two buffers for one path")
assert(
    vim.deep_equal(
        buffer.loaded_buffers_for_path(path, by_path),
        { first, second }
    ),
    "duplicate path lookup should return sorted loaded buffers"
)
vim.api.nvim_set_current_buf(second)
assert(
    buffer.loaded_buffer_for_path(path, by_path) == second,
    "current duplicate buffer should be preferred"
)

vim.api.nvim_set_current_buf(first)
assert(
    buffer.loaded_buffer_for_path(path, by_path) == first,
    "current buffer should win when it shares the requested path"
)

vim.cmd.enew()
assert(
    buffer.loaded_buffer_for_path(path, by_path) == second,
    "highest-numbered loaded buffer should win when current buffer is unrelated"
)

vim.cmd("qa!")
