local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
local ok, err = pcall(function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("compile-stdin-contract"),
        compile = {
            stdin = "hidden public field",
        },
    })
end)

assert(not ok, "compile.stdin should not be accepted as public config")
assert(
    tostring(err):find("compile.stdin is internal", 1, true),
    "compile.stdin rejection should explain the internal contract"
)

vim.cmd("qa!")
