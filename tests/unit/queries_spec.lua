local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local highlights = vim.treesitter.query.get("typst", "highlights")
assert(highlights, "typst highlights query did not load")

local textobjects = vim.treesitter.query.get("typst", "textobjects")
assert(textobjects, "typst textobjects query did not load")

local folds = vim.treesitter.query.get("typst", "folds")
assert(folds, "typst folds query did not load")

local injections = vim.treesitter.query.get("typst", "injections")
assert(injections, "typst injections query did not load")

local indents = vim.treesitter.query.get("typst", "indents")
assert(indents, "typst indents query did not load")

local conceal = vim.treesitter.query.get("typst", "conceal")
assert(conceal, "typst conceal query did not load")

local locals = vim.treesitter.query.get("typst", "locals")
assert(locals, "typst locals query did not load")

local images = vim.treesitter.query.get("typst", "images")
assert(images, "typst images query did not load")

local function collect_captures(query, tree, bufnr)
    local captures = {}
    for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
        local name = query.captures[id]
        captures[name] = captures[name] or {}
        captures[name][#captures[name] + 1] =
            vim.treesitter.get_node_text(node, bufnr)
    end
    return captures
end

local function capture_metadata(query, tree, bufnr, capture_name, text)
    for id, node, metadata in query:iter_captures(tree:root(), bufnr, 0, -1) do
        local name = query.captures[id]
        if
            name == capture_name
            and vim.treesitter.get_node_text(node, bufnr) == text
        then
            return metadata
        end
    end
end

local function has_capture_text(captures, name, expected)
    for _, text in ipairs(captures[name] or {}) do
        if text == expected then
            return true
        end
    end
    return false
end

local function has_capture_matching(captures, name, pattern)
    for _, text in ipairs(captures[name] or {}) do
        if text:match(pattern) then
            return true
        end
    end
    return false
end

local highlight_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(highlight_buf)
vim.bo[highlight_buf].filetype = "typst"
vim.api.nvim_buf_set_lines(highlight_buf, 0, -1, false, {
    "= Intro <intro>",
    "/// Source docs",
    "Markup *strong* and _emph_.",
    '#let alpha(x, y: 1) = "value"',
    '#import "lib.typ": beta as gamma',
    "Text @intro and $ alpha + arrow.r + x_1 $",
    "```typst",
    "#let z = 3",
    "```",
})
local highlight_parser =
    assert(vim.treesitter.get_parser(highlight_buf, "typst"))
local highlight_tree = assert(highlight_parser:parse()[1])

local highlight_captures =
    collect_captures(highlights, highlight_tree, highlight_buf)

assert(
    highlight_captures["markup.heading"],
    "markup.heading highlight capture missing"
)
assert(
    highlight_captures["markup.strong"],
    "markup.strong highlight capture missing"
)
assert(
    highlight_captures["punctuation.special"],
    "punctuation.special highlight capture missing"
)
assert(
    has_capture_text(highlight_captures, "variable.definition", "alpha"),
    "let bindings should capture names"
)
assert(
    has_capture_text(highlight_captures, "variable.parameter", "y"),
    "named parameters should capture parameter names"
)
assert(
    has_capture_text(highlight_captures, "string", '"value"'),
    "string highlight capture missing"
)
assert(
    highlight_captures["markup.raw.block"],
    "raw block highlight capture missing"
)

local fixture = root .. "/tests/fixtures/basic/syntax.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
local fixture_buf = vim.api.nvim_get_current_buf()

local parser = assert(vim.treesitter.get_parser(fixture_buf, "typst"))
local tree = assert(parser:parse()[1])

local syntax_highlight_captures =
    collect_captures(highlights, tree, fixture_buf)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "comment",
        "/// Build a local documented helper."
    ),
    "syntax fixture should capture documentation comments"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "comment.todo",
        "// TODO: tighten package syntax captures."
    ),
    "TODO comments should receive a dedicated highlight capture"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "comment.note",
        "// NOTE: parser-backed fixtures cover editor queries."
    ),
    "NOTE comments should receive a dedicated highlight capture"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "comment.warning",
        "// WARN: lossy conceal should stay opt-in."
    ),
    "WARN comments should receive a dedicated highlight capture"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "comment.error",
        "// FIXME: malformed examples live in the query test."
    ),
    "FIXME comments should receive a dedicated highlight capture"
)
assert(
    has_capture_text(syntax_highlight_captures, "markup.heading.1", "="),
    "level-1 heading capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "markup.heading.2", "=="),
    "level-2 heading capture missing"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "markup.strong",
        "*strong text*"
    ),
    "strong capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "markup.italic", "_emphasis_"),
    "emphasis capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "markup.raw", "`raw inline`"),
    "raw span capture missing"
)
assert(
    has_capture_matching(
        syntax_highlight_captures,
        "spell",
        "^This paragraph has"
    ),
    "prose text should be marked as a spell-checking region"
)
assert(
    has_capture_text(
        syntax_highlight_captures,
        "spell",
        "// NOTE: parser-backed fixtures cover editor queries."
    ),
    "comments should be marked as spell-checking regions"
)
assert(
    has_capture_text(syntax_highlight_captures, "spell", "Figure body"),
    "Typst content inside code calls should remain a spell-checking region"
)
local line_comment_metadata = capture_metadata(
    highlights,
    tree,
    fixture_buf,
    "comment",
    "// NOTE: parser-backed fixtures cover editor queries."
)
assert(
    line_comment_metadata
        and line_comment_metadata["bo.commentstring"] == "// %s",
    "line comments should set Tree-sitter commentstring metadata"
)
assert(
    has_capture_text(syntax_highlight_captures, "nospell", "`raw inline`"),
    "raw spans should disable spelling"
)
assert(
    has_capture_text(syntax_highlight_captures, "markup.list", "-"),
    "list marker highlight capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "keyword.import", "import"),
    "import keyword capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "keyword.operator", "as"),
    "as keyword capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "function.call", "figure"),
    "function call capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "variable.parameter", "caption"),
    "named parameter capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "constant", "arrow.r"),
    "math field capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "number", "2"),
    "math number capture missing"
)
assert(
    has_capture_text(syntax_highlight_captures, "string.special", "typst"),
    "raw language capture missing"
)
assert(
    has_capture_matching(syntax_highlight_captures, "nospell", "alpha %+"),
    "math should disable spelling"
)
assert(
    has_capture_text(syntax_highlight_captures, "nospell", '"demo"'),
    "strings should disable spelling"
)

local malformed_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(malformed_buf)
vim.bo[malformed_buf].filetype = "typst"
vim.api.nvim_buf_set_lines(malformed_buf, 0, -1, false, {
    "#let broken = [",
    "#figure([Body], caption: [Missing",
})
local malformed_parser =
    assert(vim.treesitter.get_parser(malformed_buf, "typst"))
local malformed_tree = assert(malformed_parser:parse()[1])
local malformed_captures =
    collect_captures(highlights, malformed_tree, malformed_buf)
assert(
    malformed_captures.error,
    "malformed Typst should receive an error highlight capture"
)

local comment_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(comment_buf)
vim.bo[comment_buf].filetype = "typst"
vim.api.nvim_buf_set_lines(comment_buf, 0, -1, false, {
    "/* block comment */",
})
local comment_parser = assert(vim.treesitter.get_parser(comment_buf, "typst"))
local comment_tree = assert(comment_parser:parse()[1])
local block_comment_metadata = capture_metadata(
    highlights,
    comment_tree,
    comment_buf,
    "comment",
    "/* block comment */"
)
assert(
    block_comment_metadata
        and block_comment_metadata["bo.commentstring"] == "/* %s */",
    "block comments should set Tree-sitter commentstring metadata"
)

local conceal_captures = collect_captures(conceal, tree, fixture_buf)
assert(
    has_capture_text(conceal_captures, "conceal.symbol", "alpha"),
    "math symbol conceal capture missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.symbol", "arrow.r"),
    "dotted math symbol conceal capture missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.emoji", "emoji.face.halo"),
    "math emoji conceal capture missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.math_delimiter", "$"),
    "math delimiter conceal capture missing"
)
assert(
    has_capture_matching(conceal_captures, "conceal.script", "x_1"),
    "subscript conceal capture missing"
)
assert(
    has_capture_matching(conceal_captures, "conceal.script", "y%^2"),
    "superscript conceal capture missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.markup_delimiter", "*"),
    "markup delimiter conceal missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.heading_marker", "=="),
    "heading marker conceal missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.list_marker", "+"),
    "alternate list marker conceal missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.raw_delimiter", "`"),
    "raw span delimiter conceal missing"
)
assert(
    conceal_captures["conceal.raw_block_fence"],
    "raw block fence conceal capture missing"
)
assert(
    conceal_captures["conceal.raw_block_language"],
    "raw block language capture missing"
)
assert(
    has_capture_text(
        conceal_captures,
        "conceal.label_delimiter",
        "<first-item>"
    ),
    "label delimiter conceal missing"
)
assert(
    has_capture_text(conceal_captures, "conceal.reference_marker", "@"),
    "reference marker conceal missing"
)
assert(
    conceal_captures["conceal.function_wrapper"],
    "function wrapper conceal capture missing"
)

local textobject_captures = collect_captures(textobjects, tree, fixture_buf)

assert(
    textobject_captures["heading.outer"],
    "heading.outer text object capture missing"
)
assert(
    has_capture_text(textobject_captures, "heading.inner", "Syntax Fixture"),
    "heading.inner should capture heading text"
)
assert(
    textobject_captures["section.outer"],
    "section.outer text object capture missing"
)
assert(
    textobject_captures["equation.outer"],
    "equation.outer text object capture missing"
)
assert(
    has_capture_matching(textobject_captures, "equation.inner", "alpha %+"),
    "equation.inner should capture inline math"
)
assert(
    textobject_captures["content.outer"],
    "content.outer text object capture missing"
)
assert(
    textobject_captures["block.outer"],
    "block.outer text object capture missing"
)
assert(
    textobject_captures["structural_block.outer"],
    "structural_block.outer capture missing"
)
assert(
    textobject_captures["code_block.outer"],
    "code_block.outer capture missing"
)
assert(
    textobject_captures["raw_block.outer"],
    "raw_block.outer capture missing"
)
assert(
    textobject_captures["list_item.outer"],
    "list_item.outer text object capture missing"
)
assert(
    has_capture_text(textobject_captures, "label.outer", "<first-item>"),
    "label.outer should capture labels"
)
assert(
    has_capture_text(textobject_captures, "label.outer", "@first-item"),
    "label.outer should capture references"
)
assert(
    textobject_captures["import.outer"],
    "import.outer text object capture missing"
)
assert(
    has_capture_text(textobject_captures, "call.outer", "strong[wrapped]"),
    "call.outer should capture calls"
)
assert(
    has_capture_matching(textobject_captures, "call.outer", "^figure%("),
    "call.outer should capture multiline calls"
)
assert(
    textobject_captures["argument.outer"],
    "argument.outer text object capture missing"
)
assert(
    textobject_captures["argument.inner"],
    "argument.inner text object capture missing"
)
assert(
    has_capture_text(textobject_captures, "argument.inner", "Figure body"),
    "argument.inner should capture bracketed content text"
)
assert(
    has_capture_text(textobject_captures, "argument.inner", "Figure caption"),
    "argument.inner should capture named content value text"
)
assert(
    has_capture_text(textobject_captures, "argument.inner", '"demo"'),
    "argument.inner should capture string arguments"
)

local captures = collect_captures(injections, tree, fixture_buf)

assert(
    has_capture_text(captures, "injection.language", "typst"),
    "injection language capture was wrong"
)
assert(
    has_capture_matching(captures, "injection.content", "#let z = 3"),
    "injection content capture was wrong"
)

local fold_captures = collect_captures(folds, tree, fixture_buf)
assert(fold_captures.fold, "fold query should capture structural blocks")
assert(
    has_capture_matching(fold_captures, "fold", "^```typst"),
    "fold query should capture raw blocks"
)

local indent_captures = collect_captures(indents, tree, fixture_buf)

assert(indent_captures["indent.scope"], "indent.scope capture missing")
assert(indent_captures["indent.ignore"], "indent.ignore capture missing")

local markdown_injections = vim.treesitter.query.get("markdown", "injections")
assert(markdown_injections, "markdown injections query did not load")

local markdown_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(markdown_buf)
vim.bo[markdown_buf].filetype = "markdown"
vim.api.nvim_buf_set_lines(markdown_buf, 0, -1, false, {
    "# Host Document",
    "",
    "```typst",
    "#let x = 1",
    "$ alpha + beta $",
    "```",
    "",
    "```text",
    "#let this_is_not_typst = true",
    "```",
})
local markdown_parser =
    assert(vim.treesitter.get_parser(markdown_buf, "markdown"))
local markdown_tree = assert(markdown_parser:parse()[1])
local markdown_captures =
    collect_captures(markdown_injections, markdown_tree, markdown_buf)

assert(
    has_capture_text(markdown_captures, "injection.language", "typst"),
    "typst fence language capture missing"
)
assert(
    has_capture_matching(markdown_captures, "injection.content", "#let x = 1"),
    "typst fence content capture missing"
)
assert(
    not has_capture_matching(
        markdown_captures,
        "injection.content",
        "this_is_not_typst"
    ),
    "non-typst fenced code should not be injected as Typst"
)

vim.cmd("qa!")
