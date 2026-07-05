local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local windows = require("typst.core.windows")

local bufnr = vim.api.nvim_get_current_buf()
local winid = vim.api.nvim_get_current_win()

assert(
    windows.has_buffer(tostring(winid), bufnr),
    "window helpers should accept WinClosed-style string ids"
)
---@type any
local string_win_opts = { winid = tostring(winid) }
assert(
    windows.for_buffer(bufnr, string_win_opts) == winid,
    "for_buffer should normalize string window ids"
)
assert(
    windows.has_buffer("not-a-window", bufnr) == false,
    "invalid string window ids should be rejected safely"
)
---@type any
local invalid_win_opts = { winid = "not-a-window" }
assert(
    windows.for_buffer(bufnr, invalid_win_opts) == nil,
    "strict lookup should return nil for invalid requested window ids"
)

vim.cmd("qa!")
