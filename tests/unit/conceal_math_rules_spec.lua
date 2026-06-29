local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-math-rules-output"),
})

local function matches_for(line)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.bo[bufnr].filetype = "typst"
    return require("typst.conceal").matches(bufnr)
end

local function source_map(items)
    local by_text = {}
    for _, match in ipairs(items) do
        by_text[match.source_text] = match
    end
    return by_text
end

local by_source =
    source_map(matches_for("$ cal(A) + bb(R) + frak(g) + bold(x) + cal(AB) $"))

assert(
    by_source["cal(A)"] and by_source["cal(A)"].replacement == "𝒜",
    "cal(A) should conceal as mathematical script A"
)
assert(
    by_source["bb(R)"] and by_source["bb(R)"].replacement == "ℝ",
    "bb(R) should conceal as double-struck R"
)
assert(
    by_source["frak(g)"] and by_source["frak(g)"].replacement == "𝔤",
    "frak(g) should conceal as fraktur g"
)
assert(
    by_source["bold(x)"] and by_source["bold(x)"].replacement == "𝐱",
    "bold(x) should conceal as mathematical bold x"
)
assert(
    not by_source["cal(AB)"],
    "font conceal should require a single-letter operand"
)

by_source = source_map(matches_for("$ a <= b + a -> b + a != b $"))
assert(
    by_source["<="] and by_source["<="].replacement == "≤",
    "<= should conceal"
)
assert(
    by_source["->"] and by_source["->"].replacement == "→",
    "-> should conceal"
)
assert(
    by_source["!="] and by_source["!="].replacement == "≠",
    "!= should conceal"
)

by_source = source_map(
    matches_for("$ abs(x) + norm(x) + floor(x) + ceil(x) + sqrt(x) $")
)
assert(
    by_source["abs("] and by_source["abs("].replacement == "|",
    "abs prefix should conceal"
)
assert(
    by_source[")"] and by_source[")"].replacement,
    "wrapper suffixes should conceal"
)

local suffix_count = 0
for _, match in
    ipairs(matches_for("$ abs(x) + norm(x) + floor(x) + ceil(x) + sqrt(x) $"))
do
    if match.category == "math_wrappers" and match.part == "suffix" then
        suffix_count = suffix_count + 1
    end
end
assert(
    suffix_count == 5,
    "all configured math wrappers should produce suffix matches"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-math-rules-output"),
    conceal = {
        categories = {
            math_fonts = false,
            math_operators = false,
            math_wrappers = false,
        },
    },
})
by_source = source_map(matches_for("$ cal(A) + a <= b + abs(x) $"))
assert(not by_source["cal(A)"], "math font category should be disableable")
assert(not by_source["<="], "math operator category should be disableable")
assert(not by_source["abs("], "math wrapper category should be disableable")

vim.cmd("qa!")
