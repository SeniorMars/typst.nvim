local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("bibliography-edit-output"),
})
local bibliography = typst.bibliography

local bib = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bib)
vim.bo[bib].filetype = "bib"
vim.bo[bib].shiftwidth = 2
vim.api.nvim_buf_set_lines(bib, 0, -1, false, {
    "@article{doe2020,",
    "title = {Fixture},",
    "}",
})
assert(
    bibliography.foldexpr(1, bib) == ">1",
    "BibTeX entry starts should open folds"
)
assert(
    bibliography.foldexpr(3, bib) == "<1",
    "BibTeX entry ends should close folds"
)
assert(
    bibliography.indentexpr(1, bib) == 0,
    "BibTeX entry starts should stay at column zero"
)
assert(
    bibliography.indentexpr(2, bib) == 2,
    "BibTeX fields should indent inside entries"
)
assert(
    bibliography.indentexpr(3, bib) == 0,
    "BibTeX closing braces should deindent"
)
vim.api.nvim_buf_set_lines(bib, 0, 1, false, { "not an entry" })
assert(
    bibliography.indentexpr(2, bib) == 0,
    "BibTeX indent cache should refresh after buffer edits"
)

local yaml = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(yaml)
vim.bo[yaml].filetype = "yaml"
vim.bo[yaml].shiftwidth = 2
vim.api.nvim_buf_set_lines(yaml, 0, -1, false, {
    "doe2020:",
    "title: Fixture",
    "author:",
    "- Doe, Jane",
})
assert(
    bibliography.foldexpr(1, yaml) == ">1",
    "Hayagriva top-level entries should open folds"
)
assert(
    bibliography.foldexpr(2, yaml) == "0",
    "Hayagriva top-level fields should not stay folded as entries"
)
assert(
    bibliography.indentexpr(1, yaml) == 0,
    "Hayagriva entry keys should stay at column zero"
)
assert(
    bibliography.indentexpr(2, yaml) == 2,
    "Hayagriva fields should indent after entry keys"
)
assert(
    bibliography.indentexpr(4, yaml) == 2,
    "Hayagriva sequences should indent after field keys"
)

vim.cmd("qa!")
