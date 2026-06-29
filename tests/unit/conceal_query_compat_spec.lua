local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local query = vim.treesitter.query.get("typst", "conceal")
assert(query, "typst conceal query should load")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "$ cal(A) + bb(R) + frak(g) + bold(x) + a <= b + a -> b + a != b + abs(x) + norm(x) + sqrt(x) $",
})

local parser = vim.treesitter.get_parser(bufnr, "typst")
local tree = parser:parse()[1]
assert(tree, "typst parser should produce a tree")

local captures = {}
for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local name = query.captures[id]
    captures[name] = captures[name] or {}
    captures[name][#captures[name] + 1] =
        vim.treesitter.get_node_text(node, bufnr)
end

local function has_capture(name, text)
    for _, captured in ipairs(captures[name] or {}) do
        if captured == text then
            return true
        end
    end
    return false
end

for _, text in ipairs({
    "cal(A)",
    "bb(R)",
    "frak(g)",
    "bold(x)",
    "abs(x)",
    "norm(x)",
    "sqrt(x)",
}) do
    assert(
        has_capture("conceal.math_call", text),
        ("conceal query should capture math call %s"):format(text)
    )
end

for _, text in ipairs({ "<=", "->", "!=" }) do
    assert(
        has_capture("conceal.math_operator", text),
        ("conceal query should capture math operator %s"):format(text)
    )
end

vim.cmd("qa!")
