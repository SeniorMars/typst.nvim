local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local ftplugin_state = require("typst.core.ftplugin_state")

ftplugin_state.reset()

local buf_a = vim.api.nvim_create_buf(true, true)
local buf_b = vim.api.nvim_create_buf(true, true)
local win = vim.api.nvim_get_current_win()

vim.api.nvim_set_current_buf(buf_a)
vim.wo[win].conceallevel = 0
assert(
    ftplugin_state.set_window_option(buf_a, win, "conceallevel", 2),
    "test should install a window-local option for buffer A"
)
assert(vim.wo[win].conceallevel == 2, "Typst option should be installed")

vim.api.nvim_set_current_buf(buf_b)
vim.wo[win].conceallevel = 1
ftplugin_state.restore(buf_a)

assert(
    vim.api.nvim_win_get_buf(win) == buf_b,
    "test window should now show buffer B"
)
assert(
    vim.wo[win].conceallevel == 1,
    "restoring buffer A must not mutate window options for buffer B"
)

vim.cmd("qa!")
