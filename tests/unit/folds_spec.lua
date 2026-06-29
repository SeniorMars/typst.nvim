local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("folds-output"),
})

local fixture = root .. "/tests/fixtures/basic/editing.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"

local applied = require("typst.edit.folds").apply(0)
assert(applied, "Typst folds should apply for Typst buffers")
assert(vim.wo.foldmethod == "expr", "foldmethod should use expression folds")
assert(
    vim.wo.foldexpr == "v:lua.typst_nvim_foldexpr()",
    "foldexpr should use Typst folds"
)
assert(
    vim.wo.foldlevel == 99,
    "foldlevel should keep Typst buffers open by default"
)
assert(
    vim.wo.foldtext == "v:lua.typst_nvim_foldtext()",
    "foldtext should use Typst folds"
)
assert(vim.fn.foldlevel(1) > 0, "heading should produce a fold level")
assert(
    vim.fn.foldlevel(5) > vim.fn.foldlevel(1),
    "nested heading should produce a deeper fold level"
)
assert(
    require("typst.edit.folds").foldtext():find("%[", 1, false),
    "foldtext should include a line count"
)
assert(
    require("typst.edit.folds").refresh(0) >= 1,
    "fold refresh should refresh visible Typst windows"
)

local original_get_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function()
    error("missing typst parser")
end

local fallback_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fallback_buf)
vim.api.nvim_buf_set_lines(fallback_buf, 0, -1, false, {
    "= Fallback",
    "",
    "body",
    "== Nested",
})
vim.bo[fallback_buf].filetype = "typst"
local fallback_applied = require("typst.edit.folds").apply(fallback_buf)
vim.treesitter.get_parser = original_get_parser
assert(fallback_applied, "heading folds should apply without a Typst parser")
assert(
    vim.b[fallback_buf].typst_nvim_fold_backend == "headings",
    "missing parser should use heading folds"
)
assert(vim.fn.foldlevel(1) > 0, "fallback heading should produce a fold level")
assert(
    vim.fn.foldlevel(4) > vim.fn.foldlevel(1),
    "fallback nested heading should produce a deeper fold level"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("folds-output"),
    folds = {
        headings = false,
    },
})
local no_heading_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(no_heading_buf)
vim.api.nvim_buf_set_lines(no_heading_buf, 0, -1, false, {
    "= Not folded",
    "body",
})
vim.bo[no_heading_buf].filetype = "typst"
require("typst.edit.folds").apply(no_heading_buf)
assert(
    vim.fn.foldlevel(1) == 0,
    "disabled heading folds should not fold heading lines"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("folds-output"),
    folds = {
        mode = "manual",
    },
})
local manual_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(manual_buf)
vim.api.nvim_buf_set_lines(manual_buf, 0, -1, false, { "= Manual" })
vim.bo[manual_buf].filetype = "typst"
require("typst.edit.folds").apply(manual_buf)
assert(
    vim.wo.foldmethod == "manual",
    "manual fold mode should install manual foldmethod"
)

vim.cmd("qa!")
