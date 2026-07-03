local root = vim.fn.getcwd()
local help = table.concat(vim.fn.readfile(root .. "/doc/typst.txt"), "\n")

for _, tag in ipairs({
    "typst-start",
    "typst-main-resolution",
    "typst-compile-lifecycle",
    "typst-watch",
    "typst-output-locks",
    "typst-preview-native",
    "typst-source-sync",
    "typst-tinymist",
    "typst-completion",
    "typst-conceal",
    "typst-provider-contracts",
    "typst-debugging",
}) do
    assert(help:find("*" .. tag .. "*", 1, true), "missing help tag: " .. tag)
end

vim.cmd("qa!")
