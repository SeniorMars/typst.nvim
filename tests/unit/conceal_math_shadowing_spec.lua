local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-math-shadowing-output"),
})

local function matches_for(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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

local by_source = source_map(matches_for({
    "#let cal(x) = x",
    "#let abs(x) = x",
    "$ cal(A) + bb(R) + abs(x) + norm(x) $",
}))
assert(
    not by_source["cal(A)"],
    "local cal binding should suppress math font conceal"
)
assert(
    by_source["bb(R)"] and by_source["bb(R)"].replacement == "ℝ",
    "unshadowed math font calls should still conceal"
)
assert(
    not by_source["abs("],
    "local abs binding should suppress math wrapper conceal"
)
assert(
    by_source["norm("] and by_source["norm("].replacement == "‖",
    "unshadowed math wrapper calls should still conceal"
)

by_source = source_map(matches_for({
    '#import "math.typ": cal, norm',
    "$ cal(A) + bb(R) + norm(x) + abs(x) $",
}))
assert(
    not by_source["cal(A)"],
    "imported cal binding should suppress math font conceal"
)
assert(
    by_source["bb(R)"] and by_source["bb(R)"].replacement == "ℝ",
    "unshadowed imported-context math font calls should still conceal"
)
assert(
    not by_source["norm("],
    "imported norm binding should suppress math wrapper conceal"
)
assert(
    by_source["abs("] and by_source["abs("].replacement == "|",
    "unshadowed imported-context wrapper calls should still conceal"
)

by_source = source_map(matches_for({
    '#import "math.typ": other as cal, other-wrapper as abs',
    "$ cal(A) + bb(R) + abs(x) + norm(x) $",
}))
assert(
    not by_source["cal(A)"],
    "import alias cal binding should suppress math font conceal"
)
assert(
    by_source["bb(R)"] and by_source["bb(R)"].replacement == "ℝ",
    "unshadowed import-alias context math font calls should still conceal"
)
assert(
    not by_source["abs("],
    "import alias abs binding should suppress math wrapper conceal"
)
assert(
    by_source["norm("] and by_source["norm("].replacement == "‖",
    "unshadowed import-alias context wrapper calls should still conceal"
)

by_source = source_map(matches_for({
    '#import "math.typ": *',
    "$ bb(R) + norm(x) $",
}))
assert(
    not by_source["bb(R)"],
    "wildcard imports should suppress implicit math font built-ins"
)
assert(
    not by_source["norm("],
    "wildcard imports should suppress implicit math wrapper built-ins"
)

vim.cmd("qa!")
