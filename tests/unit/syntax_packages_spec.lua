local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("syntax-packages-output"),
    syntax = {
        packages = {
            ["@preview/article-template"] = {
                name = "article_template",
                capture = "@typst.package.article_template",
                highlight_group = "TypstPackageTemplate",
                members = { "with" },
            },
        },
    },
})
local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
local project =
    assert(typst.project.attach(0), "syntax package fixture should attach")
local original_line_count = vim.api.nvim_buf_line_count(0)
local fake_package_lines = {
    "Plain prose mentions canvas template.with.",
    '#let package-string = "canvas template.with"',
    "// canvas template.with",
    "Inline package raw: `canvas template.with`",
    "```typ",
    "#canvas({})",
    "#template.with(title: [Raw])",
    "```",
}
vim.api.nvim_buf_set_lines(0, -1, -1, false, fake_package_lines)
local plain_package_row = original_line_count
local fake_package_rows = {}
for offset = 1, #fake_package_lines - 1 do
    fake_package_rows[original_line_count + offset] = true
end

local function has_extension(extensions, package_key)
    for _, extension in ipairs(extensions) do
        if extension.package_key == package_key then
            return extension
        end
    end
end

local extensions = typst.syntax.package_extensions({ project = project })
local cetz = assert(
    has_extension(extensions, "@preview/cetz"),
    "CeTZ package extension should be active"
)
assert(
    cetz.capture == "@typst.package.cetz",
    "CeTZ extension should expose its syntax capture"
)
assert(
    cetz.highlight_group == "TypstPackageCetz",
    "CeTZ extension should expose its highlight group"
)

local template = assert(
    has_extension(extensions, "@preview/article-template"),
    "custom package extension should be active"
)
assert(
    template.capture == "@typst.package.article_template",
    "custom package extension should expose its capture"
)

local matches = typst.syntax.package_matches({ bufnr = 0 })
local function find_match(name, package_key, list)
    for _, match in ipairs(list or matches) do
        if match.name == name and match.package_key == package_key then
            return match
        end
    end
end

local canvas_match = assert(
    find_match("canvas", "@preview/cetz"),
    "CeTZ canvas import/use should match"
)
assert(
    canvas_match.capture == "@typst.package.cetz",
    "CeTZ match should carry capture metadata"
)
assert(
    canvas_match.hl_group == "TypstPackageCetz",
    "CeTZ match should carry highlight group"
)

local template_match = assert(
    find_match("template.with", "@preview/article-template"),
    "custom package member path should match"
)
assert(
    template_match.hl_group == "TypstPackageTemplate",
    "custom package member should carry highlight group"
)

local semantic_matches = typst.syntax.package_matches({
    bufnr = 0,
    semantic_tokens = function(_, candidate)
        if candidate.text == "template.with" then
            return true
        end
        if candidate.text == "canvas" then
            return false
        end
    end,
})
local semantic_template = assert(
    find_match("template.with", "@preview/article-template", semantic_matches),
    "semantic token-approved package member should match"
)
assert(
    semantic_template.semantic_token == true,
    "semantic token-approved package member should carry evidence"
)
assert(
    not find_match("canvas", "@preview/cetz", semantic_matches),
    "semantic token-rejected package candidate should not match"
)

local semantic_required_without_evidence = typst.syntax.package_matches({
    bufnr = 0,
    semantic_proof = "required",
    semantic_tokens = false,
})
assert(
    not find_match(
        "template.with",
        "@preview/article-template",
        semantic_required_without_evidence
    ),
    "required semantic proof should reject package candidates without semantic evidence"
)

local semantic_required_matches = typst.syntax.package_matches({
    bufnr = 0,
    semantic_proof = "required",
    semantic_tokens = function(_, candidate)
        return candidate.text == "template.with"
    end,
})
assert(
    find_match(
        "template.with",
        "@preview/article-template",
        semantic_required_matches
    ),
    "required semantic proof should allow semantic-token-approved package members"
)
assert(
    not find_match("canvas", "@preview/cetz", semantic_required_matches),
    "required semantic proof should reject semantic-token-denied package candidates"
)

local malformed_semantic_matches = typst.syntax.package_matches({
    bufnr = 0,
    semantic_proof = "required",
    semantic_tokens = {
        { type = "function" },
    },
})
assert(
    not find_match(
        "template.with",
        "@preview/article-template",
        malformed_semantic_matches
    ),
    "required semantic proof should reject semantic tokens without ranges"
)

local semantic_off_matches = typst.syntax.package_matches({
    bufnr = 0,
    semantic_proof = "off",
    semantic_tokens = function()
        return false
    end,
})
assert(
    find_match("canvas", "@preview/cetz", semantic_off_matches),
    "semantic proof off should preserve bounded syntactic fallback behavior"
)

for _, match in ipairs(matches) do
    assert(
        not fake_package_rows[(match.range or {}).row],
        "package highlights should ignore strings, comments, and raw text"
    )
end

local parser_available = pcall(vim.treesitter.get_parser, 0, "typst")
if parser_available then
    for _, match in ipairs(matches) do
        assert(
            (match.range or {}).row ~= plain_package_row,
            "Tree-sitter package highlights should ignore plain prose"
        )
    end
end

local applied = typst.syntax.refresh(0)
assert(
    #applied >= #matches,
    "syntax.refresh should return applied package matches"
)

local extmarks = vim.api.nvim_buf_get_extmarks(
    0,
    typst.syntax.namespace(),
    0,
    -1,
    { details = true }
)
assert(#extmarks > 0, "syntax.refresh should apply package highlight extmarks")

local marked_canvas = false
for _, mark in ipairs(extmarks) do
    local details = mark[4] or {}
    if details.hl_group == "TypstPackageCetz" then
        marked_canvas = true
        break
    end
end
assert(marked_canvas, "CeTZ package highlight extmark missing")

vim.cmd("qa!")
