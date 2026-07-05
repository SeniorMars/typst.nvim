local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local required = vim.env.TYPST_NVIM_REQUIRE_TREESITTER == "1"

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "// line comment",
    "/* block comment */",
    "= Heading <intro>",
    "#let alpha(x, y: 1) = x + y",
    '#import "lib.typ": beta as gamma',
    "#figure([Body], caption: [Cap])",
    "Markup _emph_ and @intro with $ alpha + arrow.r + x_1 $.",
    "```typst",
    "#let z = 3",
    "```",
})
local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
if not ok_parser or not parser then
    assert(not required, "SeniorMars Typst parser is required but unavailable")
    print("parser_compat_spec skipped: Typst parser unavailable")
    vim.cmd("qa!")
end

parser = assert(parser)
local tree = parser:parse()[1]
assert(tree, "Typst parser did not return a syntax tree")

local named_types = {}
local function walk(node)
    if node:named() then
        named_types[node:type()] = true
    end
    for child in node:iter_children() do
        walk(child)
    end
end
walk(tree:root())

for _, node_type in ipairs({
    "line_comment",
    "block_comment",
    "content",
    "content_block",
    "embedded_code",
    "heading_body",
    "let_binding",
    "parameters",
    "named_parameter",
    "function_call",
    "arguments",
    "module_import",
    "import_item",
    "import_path",
    "reference",
    "equation",
    "math",
    "math_identifier",
    "math_field_access",
    "math_attachment",
    "raw",
    "raw_language",
    "raw_content",
}) do
    assert(
        named_types[node_type],
        ("SeniorMars parser node %q was not produced"):format(node_type)
    )
end

for _, old_node_type in ipairs({
    "comment",
    "ident",
    "call",
    "import",
    "ref",
    "emph",
    "formula",
    "raw_blck",
    "raw_span",
    "block",
    "group",
    "tagged",
    "field",
    "parenthesized_arguments",
    "embedded_code_expression",
    "code",
}) do
    assert(
        not named_types[old_node_type],
        ("old Typst parser named node %q is still active"):format(old_node_type)
    )
end

vim.cmd("qa!")
