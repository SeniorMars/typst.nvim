local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("imaps-output"),
})

local imaps = typst.imaps
local imap_engine = require("typst.edit.imaps")
assert(
    type(imaps.register) == "function",
    "imaps registry should expose register"
)
assert(#imaps.active(0) == 0, "imaps should be disabled by default")
assert(#imaps.list() > 0, "imaps list should include built-ins")

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("imaps-output"),
    imaps = {
        enabled = true,
    },
})

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "typst"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$ " })
vim.api.nvim_win_set_cursor(0, { 1, 2 })

local active = imaps.active(buf)
assert(#active > 0, "enabled imaps should report active mappings")
assert(
    imap_engine.expand(";a", buf) == "alpha",
    "math imap should expand in math context"
)

local id = imaps.register({
    lhs = ";u",
    rhs = "unit",
    modes = { "math" },
    priority = 100,
    description = "unit test symbol",
})
assert(type(id) == "string" and id ~= "", "imaps.register should return an id")
assert(imap_engine.expand(";u", buf) == "unit", "registered imap should expand")
assert(
    imaps.unregister(id),
    "imaps.unregister should remove registered entries"
)
assert(
    imap_engine.expand(";u", buf) == ";u",
    "unregistered imap should no longer expand"
)

imap_engine.apply(buf)
assert(
    vim.fn.maparg(";a", "i") ~= "",
    "enabled imaps should install insert-mode maps"
)

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Text " })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
assert(
    imap_engine.expand(";m", buf):find("$", 1, true),
    "markup imap should expand in markup context"
)

vim.cmd("TypstImapsList")
vim.cmd("TypstImapsList!")

vim.cmd("qa!")
