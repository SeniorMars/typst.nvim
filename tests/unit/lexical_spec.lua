local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lexical = require("typst.syntax.lexical")

local lines = {
    'Don\'t hide @apostrophe-ref <apostrophe:label> #include "chapter.typ"',
    "Alice's #let possessive-helper() = none",
    '#let text = "ignore @string <string:label> \\" )"',
    '#link("https://example.com/path?x=(y)")[Docs]',
    "// @comment <comment:label> #let comment-helper() = none",
    "/* @outer /* @nested */ <comment:block> */ @after-comment",
    "Inline raw: `@raw <raw:label> #let raw-helper() = none` @after-raw",
    "```typ",
    "@raw-block <raw:block> #let raw-block-helper() = none",
    "```",
    "@after-block",
}

local code = lexical.mask_lines(lines, {
    strings = "space",
    comments = "space",
    raw = "space",
})

assert(
    code[1]:find("@apostrophe%-ref"),
    "contractions should not hide later references"
)
assert(
    code[1]:find("<apostrophe:label>", 1, true),
    "contractions should not hide later labels"
)
assert(
    code[1]:find("#include", 1, true),
    "contractions should not hide later imports"
)
assert(
    code[2]:find("possessive%-helper"),
    "possessives should not hide later definitions"
)
assert(
    not code[3]:find("@string", 1, true),
    "double-quoted strings should be masked"
)
assert(
    not code[3]:find(")", 1, true),
    "escaped delimiters in strings should be masked"
)
assert(
    not code[4]:find("https://", 1, true),
    "URLs in strings should be masked"
)
assert(not code[5]:find("@comment", 1, true), "line comments should be masked")
assert(
    not code[6]:find("@outer", 1, true),
    "nested block comments should be masked"
)
assert(
    code[6]:find("@after%-comment"),
    "code after nested block comments should remain visible"
)
assert(not code[7]:find("@raw", 1, true), "inline raw text should be masked")
assert(
    code[7]:find("@after%-raw"),
    "code after inline raw text should remain visible"
)
assert(
    not code[9]:find("@raw%-block"),
    "fenced raw block contents should be masked"
)
assert(
    code[11]:find("@after%-block"),
    "code after fenced raw blocks should remain visible"
)

local keep_strings = lexical.mask_lines(lines, {
    strings = "keep",
    comments = "space",
    raw = "space",
})
assert(
    keep_strings[1]:find('"chapter.typ"', 1, true),
    "string-preserving masks should keep import paths"
)
assert(
    keep_strings[3]:find("@string", 1, true),
    "string-preserving masks should keep string contents"
)

local apostrophe_col = lines[1]:find("'", 1, true) - 1
local string_col = lines[3]:find("@string", 1, true) - 1
local raw_col = lines[7]:find("@raw", 1, true) - 1
local comment_col = lines[5]:find("@comment", 1, true) - 1

assert(
    lexical.context_at(lines, 0, apostrophe_col) == "code",
    "apostrophes should be code, not strings"
)
assert(
    lexical.context_at(lines, 2, string_col) == "string",
    "double-quoted content should be string context"
)
assert(
    lexical.context_at(lines, 6, raw_col) == "raw",
    "inline raw content should be raw context"
)
assert(
    lexical.context_at(lines, 4, comment_col) == "comment",
    "line comments should be comment context"
)
assert(
    lexical.context_at(lines, 8, 0) == "raw",
    "fenced raw contents should be raw context"
)

assert(
    lexical
        .strip_line_comment("Visit https://example.com/path now.")
        :find("example", 1, true),
    "URL slashes should not start a fallback line comment"
)
assert(
    lexical.strip_line_comment("Keep this // discard this") == "Keep this ",
    "plain double slashes should still start a fallback line comment"
)

vim.cmd("qa!")
