local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local conceal = require("typst.conceal")
local ftplugin_state = require("typst.core.ftplugin_state")
local typst = require("typst")

ftplugin_state.reset()

local winid = vim.api.nvim_get_current_win()

local typst_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(typst_buf)
vim.wo[winid].foldlevel = 3
assert(
    ftplugin_state.set_window_option(typst_buf, winid, "foldlevel", 99),
    "test should install a tracked Typst window option"
)

local other_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other_buf)
vim.wo[winid].foldlevel = 99
ftplugin_state.restore(typst_buf)
assert(
    vim.wo[winid].foldlevel == 99,
    "tracked window options should not restore into a window showing another buffer"
)

vim.api.nvim_set_current_buf(typst_buf)
vim.wo[winid].foldlevel = 4
assert(ftplugin_state.set_window_option(typst_buf, winid, "foldlevel", 99))
vim.api.nvim_set_current_buf(other_buf)
vim.wo[winid].foldlevel = 42
ftplugin_state.restore(typst_buf)
assert(
    vim.wo[winid].foldlevel == 42,
    "window restore should not overwrite user-modified values"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("window-option-restore-output"),
    conceal = {
        enabled = true,
        conceallevel = 2,
    },
})
vim.api.nvim_set_current_buf(typst_buf)
vim.bo[typst_buf].filetype = "typst"
vim.wo[winid].conceallevel = 0
assert(conceal.apply(typst_buf, winid), "conceal should apply for Typst buffer")
vim.api.nvim_set_current_buf(other_buf)
vim.wo[winid].conceallevel = 2
conceal.detach(typst_buf)
assert(
    vim.wo[winid].conceallevel == 2,
    "conceallevel should not restore into a window showing another buffer"
)

local typst_buf_user = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(typst_buf_user)
vim.bo[typst_buf_user].filetype = "typst"
vim.wo[winid].conceallevel = 0
assert(conceal.apply(typst_buf_user, winid))
vim.api.nvim_set_current_buf(other_buf)
vim.wo[winid].conceallevel = 3
conceal.detach(typst_buf_user)
assert(
    vim.wo[winid].conceallevel == 3,
    "conceal restore should not overwrite user-modified conceallevel"
)

local typst_buf_a = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(typst_buf_a)
vim.bo[typst_buf_a].filetype = "typst"
vim.wo[winid].conceallevel = 0
assert(conceal.apply(typst_buf_a, winid))

local typst_buf_b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(typst_buf_b)
vim.bo[typst_buf_b].filetype = "typst"
assert(
    vim.wo[winid].conceallevel == 2,
    "second Typst buffer should inherit the installed window conceallevel"
)
assert(conceal.apply(typst_buf_b, winid))
conceal.detach(typst_buf_b)
assert(
    vim.wo[winid].conceallevel == 0,
    "conceal restore should preserve the pre-Typst baseline across Typst buffers"
)

vim.cmd("qa!")
