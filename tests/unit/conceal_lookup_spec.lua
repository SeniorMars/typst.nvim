local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-lookup-output"),
})

local config = require("typst.config")
local lookup = require("typst.conceal.lookup")

lookup.reset()
local opts = config.get().conceal
local first = lookup.current({ alpha = "*" }, opts)
local second = lookup.current({ alpha = "*" }, opts)
assert(
    first == second,
    "lookup cache should not depend on custom table identity"
)

vim.cmd("qa!")
