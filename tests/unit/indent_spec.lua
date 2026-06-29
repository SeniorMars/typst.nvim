local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("indent-output"),
})

local indent = require("typst.edit.indent")
local main = root .. "/tests/fixtures/basic/editing.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
vim.bo.shiftwidth = 2
typst.project.attach(0)

assert(
    vim.bo.indentexpr == "v:lua.typst_nvim_indentexpr(v:lnum)",
    "attach should install Typst indentexpr"
)
assert(vim.bo.indentkeys:find("0%]"), "attach should install Typst indentkeys")

vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "#figure(",
    "  [Hi],",
    "  caption: [",
    "    Cap",
    "  ],",
    ")",
    "- item",
    "  continuation",
    "$",
    "  a = b",
    "$",
    "```typst",
    "    #let z = 3",
    "```",
    "Don't hide (",
    "inside",
    ")",
})

assert(indent.indent(1) == 0, "top-level line should not indent")
assert(indent.indent(2) == 2, "line after an opening group should indent")
assert(indent.indent(3) == 2, "sibling argument should keep group indentation")
assert(
    indent.indent(4) == 4,
    "line after an opening content block should indent"
)
assert(indent.indent(5) == 2, "closing content delimiter should dedent")
assert(indent.indent(6) == 0, "closing group delimiter should dedent")
assert(indent.indent(8) == 2, "list continuation should align after the marker")
assert(indent.indent(10) == 2, "display math body should indent")
assert(indent.indent(11) == 0, "closing display math fence should dedent")
assert(
    indent.indent(13) == -1,
    "raw block contents should preserve existing indentation"
)
assert(
    indent.indent(16) == 2,
    "contractions should not hide opening delimiters from indentation"
)
assert(
    indent.indent(17) == 0,
    "contractions should not hide closing delimiters from indentation"
)

local original_get_lines = vim.api.nvim_buf_get_lines
local full_buffer_scans = 0
vim.api.nvim_buf_get_lines = function(
    bufnr,
    start_row,
    end_row,
    strict_indexing
)
    if start_row == 0 and end_row == -1 then
        full_buffer_scans = full_buffer_scans + 1
    end
    return original_get_lines(bufnr, start_row, end_row, strict_indexing)
end

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "" })
for _ = 1, 5 do
    assert(
        indent.indent(13) == -1,
        "cached raw block contents should preserve existing indentation"
    )
end

vim.api.nvim_buf_get_lines = original_get_lines
assert(
    full_buffer_scans <= 1,
    "raw fence protection should be cached per buffer changedtick"
)

vim.cmd("qa!")
