local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lifecycle = require("typst.core.lifecycle")
local util = require("typst.core.util")

local dir = typst_test_cache_path("lifecycle-path-equivalence")
vim.fn.mkdir(dir, "p")
local main = util.normalize(dir .. "/main.typ")
vim.fn.writefile({ "= Main" }, main)

vim.cmd.edit(vim.fn.fnameescape(main))
local bufnr = vim.api.nvim_get_current_buf()
vim.b[bufnr].typst_main = "./main.typ"

assert(
    lifecycle.explicit_main_changed(bufnr, {
        root = dir,
        main = main,
    }) == false,
    "equivalent relative main path should not force a project transition"
)

vim.b[bufnr].typst_main = dir .. "/other.typ"
assert(lifecycle.explicit_main_changed(bufnr, {
    root = dir,
    main = main,
}) == true, "different explicit main path should still force a transition")

vim.cmd("qa!")
