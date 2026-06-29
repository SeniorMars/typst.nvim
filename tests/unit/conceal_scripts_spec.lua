local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local function setup(opts)
    typst.reset()
    typst.setup(vim.tbl_deep_extend("force", {
        root = root,
        output_dir = typst_test_cache_path("conceal-scripts-output"),
    }, opts or {}))
end

local function source_map(items)
    local by_text = {}
    for _, match in ipairs(items) do
        by_text[match.source_text] = match
    end
    return by_text
end

local function buffer_matches(line)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.bo[bufnr].filetype = "typst"
    return require("typst.conceal").matches(bufnr)
end

setup()

local by_source = source_map(buffer_matches("$ x_1 + x^2 $"))
assert(
    by_source["_1"] and by_source["_1"].replacement == "₁",
    "single digit subscript should keep the compact legacy match"
)
assert(
    by_source["^2"] and by_source["^2"].replacement == "²",
    "single digit superscript should keep the compact legacy match"
)

by_source = source_map(buffer_matches("$ x_12 $"))
assert(
    by_source["_"] and by_source["_"].replacement == "",
    "script operator should hide"
)
assert(
    by_source["1"] and by_source["1"].replacement == "₁",
    "first digit should conceal"
)
assert(
    by_source["2"] and by_source["2"].replacement == "₂",
    "second digit should conceal"
)

by_source = source_map(buffer_matches("$ x^(n+1) $"))
assert(not by_source["^"], "grouped scripts should stay source text by default")

setup({
    conceal = {
        math = {
            scripts = {
                grouped = true,
                max_group_len = 4,
            },
        },
    },
})
by_source = source_map(buffer_matches("$ x^(n+1) $"))
assert(
    by_source["^"] and by_source["^"].replacement == "",
    "group operator should hide"
)
assert(
    by_source["("] and by_source["("].replacement == "",
    "opening group delimiter should hide"
)
assert(
    by_source.n and by_source.n.replacement == "ⁿ",
    "group letter should conceal"
)
assert(
    by_source["+"] and by_source["+"].replacement == "⁺",
    "group sign should conceal"
)
assert(
    by_source["1"] and by_source["1"].replacement == "¹",
    "group digit should conceal"
)
assert(
    by_source[")"] and by_source[")"].replacement == "",
    "closing group delimiter should hide"
)

setup({
    conceal = {
        math = {
            scripts = {
                grouped = true,
                max_group_len = 2,
            },
        },
    },
})
by_source = source_map(buffer_matches("$ x^(n+1) $"))
assert(
    not by_source["^"],
    "grouped scripts longer than max_group_len should stay source text"
)

vim.cmd("qa!")
