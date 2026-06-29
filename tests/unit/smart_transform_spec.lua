local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("smart-transform-output"),
})

local function edit(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

local function line(n)
    return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
end

edit({ "[body]" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
local result = typst.edit.surround_delete_delimiter(nil, { notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteDelimiter failed")
assert(
    line(1) == "body",
    "TypstSurroundDeleteDelimiter should remove the nearest delimiter pair"
)

edit({ "{body}" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_block({ notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteBlock failed")
assert(
    line(1) == "body",
    "TypstSurroundDeleteBlock should remove block delimiters"
)

edit({ "$x + y$" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
result = typst.edit.surround_delete_equation({ notify = false })
assert(result.ok, result.message or "TypstSurroundDeleteEquation failed")
assert(
    line(1) == "x + y",
    "TypstSurroundDeleteEquation should remove equation delimiters"
)

edit({ "a / b" })
result = typst.edit.toggle_fraction({ notify = false })
assert(result.ok, result.message or "TypstToggleFraction slash failed")
assert(
    line(1) == "frac(a, b)",
    "TypstToggleFraction should convert slash fractions"
)
result = typst.edit.toggle_fraction({ notify = false })
assert(result.ok, result.message or "TypstToggleFraction frac failed")
assert(line(1) == "a / b", "TypstToggleFraction should convert frac calls back")

local current_buf_for_target = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(current_buf_for_target, 0, -1, false, { "current" })
local target_buf_for_transform = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(target_buf_for_transform, 0, -1, false, { "a / b" })
result = typst.edit.toggle_fraction({
    bufnr = target_buf_for_transform,
    pos = { 0, 0 },
    notify = false,
})
assert(result.ok, result.message or "targeted TypstToggleFraction failed")
assert(
    vim.api.nvim_buf_get_lines(target_buf_for_transform, 0, -1, false)[1]
        == "frac(a, b)",
    "TypstToggleFraction should edit explicit target buffers"
)
assert(
    vim.api.nvim_buf_get_lines(current_buf_for_target, 0, -1, false)[1]
        == "current",
    "targeted TypstToggleFraction should not edit the current buffer"
)

edit({ "(x + y)" })
result = typst.edit.toggle_delimiter_size({ notify = false })
assert(result.ok, result.message or "TypstToggleDelimiterSize plain failed")
assert(line(1) == "lr(x + y)", "TypstToggleDelimiterSize should add lr")
result = typst.edit.toggle_delimiter_size({ notify = false })
assert(result.ok, result.message or "TypstToggleDelimiterSize lr failed")
assert(line(1) == "(x + y)", "TypstToggleDelimiterSize should remove lr")

edit({ "line" })
result = typst.edit.toggle_line_break({ notify = false })
assert(
    result.ok and line(1) == "line \\",
    "TypstToggleLineBreak should add a markup line break"
)
result = typst.edit.toggle_line_break({ notify = false })
assert(
    result.ok and line(1) == "line",
    "TypstToggleLineBreak should remove a markup line break"
)

edit({ "alpha" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.create_function("box", { notify = false })
assert(result.ok, result.message or "TypstCreateFunction failed")
assert(
    line(1) == "#box(alpha)",
    "TypstCreateFunction should wrap the current word"
)

edit({ "[" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
result = typst.edit.smart_close({ notify = false })
assert(result.ok, result.message or "TypstSmartClose failed")
assert(
    line(1) == "[]",
    "TypstSmartClose should insert the nearest closing delimiter"
)

local current_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local target_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "[" })
result = typst.edit.smart_close({
    bufnr = target_buf,
    row = 0,
    col = 1,
    notify = false,
})
assert(result.ok, result.message or "targeted TypstSmartClose failed")
assert(
    vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)[1] == "[]",
    "TypstSmartClose should edit explicit target buffers"
)
assert(
    vim.api.nvim_get_current_buf() == current_buf
        and vim.api.nvim_win_get_cursor(0)[2] == 0,
    "targeted TypstSmartClose should not move the unrelated current window"
)

vim.cmd("qa!")
