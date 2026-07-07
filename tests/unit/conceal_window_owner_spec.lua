local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local conceal = require("typst.conceal")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-window-owner-output"),
    conceal = {
        enabled = true,
        conceallevel = 2,
    },
})

local winid = vim.api.nvim_get_current_win()
local typst_a = vim.api.nvim_create_buf(false, true)
local typst_b = vim.api.nvim_create_buf(false, true)
local other = vim.api.nvim_create_buf(false, true)

vim.api.nvim_set_current_buf(typst_a)
vim.bo[typst_a].filetype = "typst"
vim.wo[winid].conceallevel = 0
assert(conceal.apply(typst_a, winid), "conceal should apply in buffer A")
assert(
    vim.wo[winid].conceallevel == 2,
    "conceal should install configured conceallevel"
)

vim.api.nvim_set_current_buf(other)
vim.wo[winid].conceallevel = 2
conceal.detach(typst_a)
assert(
    vim.wo[winid].conceallevel == 2,
    "detaching buffer A should not restore into a window showing another buffer"
)

vim.api.nvim_set_current_buf(typst_b)
vim.bo[typst_b].filetype = "typst"
assert(conceal.apply(typst_b, winid), "conceal should apply in buffer B")
assert(
    vim.wo[winid].conceallevel == 2,
    "buffer B should own the installed conceallevel"
)
conceal.reset()
assert(
    vim.wo[winid].conceallevel == 2,
    "conceal reset should restore buffer B's pre-apply baseline"
)

vim.wo[winid].conceallevel = 1
assert(conceal.apply(typst_b, winid), "conceal should reapply after reset")
assert(
    vim.wo[winid].conceallevel == 2,
    "conceal should re-record ownership after reset"
)
conceal.detach(typst_b)
assert(
    vim.wo[winid].conceallevel == 1,
    "final detach should restore the new buffer B baseline"
)

typst.reset({ force = true })
vim.cmd("qa!")
