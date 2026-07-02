local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local windows = require("typst.core.windows")

local bufnr = vim.api.nvim_get_current_buf()
local winid = vim.api.nvim_get_current_win()

assert(
    windows.has_buffer(tostring(winid), bufnr),
    "window helpers should accept WinClosed-style string ids"
)
assert(
    windows.for_buffer(bufnr, { winid = tostring(winid) }) == winid,
    "for_buffer should normalize string window ids"
)
assert(
    windows.has_buffer("not-a-window", bufnr) == false,
    "invalid string window ids should be rejected safely"
)
assert(
    windows.for_buffer(bufnr, { winid = "not-a-window" }) == nil,
    "strict lookup should return nil for invalid requested window ids"
)

vim.cmd("qa!")
