local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("repeat-output"),
})
local edit_repeat = require("typst.edit.repeat")
local mappings = require("typst.edit.mappings")
local original_notify = vim.notify
rawset(vim, "notify", function() end)

local function edit(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    mappings.apply(bufnr)
    return bufnr
end

local function line(n)
    return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
end

edit({
    "#strong[one]",
    "#strong[two]",
})
assert(
    vim.fn.maparg(".", "n") ~= "",
    "Typst repeat mapping should be installed by default"
)

vim.api.nvim_win_set_cursor(0, { 1, 9 })
local result = typst.edit.change_function("emph", { notify = false })
assert(result.ok, result.message or "Typst change_function failed")
assert(
    line(1) == "#emph[one]",
    "Typst change_function should transform the first call"
)

local state = edit_repeat.state(0)
assert(
    state and state.command == "TypstChangeFunction emph",
    "Typst transform should record repeat command"
)

vim.api.nvim_win_set_cursor(0, { 2, 9 })
assert(
    edit_repeat.repeat_last({ bufnr = 0 }),
    "Typst repeat fallback should replay the last transform"
)
assert(
    line(2) == "#emph[two]",
    "Typst repeat fallback should apply the last transform at the new cursor"
)

edit({
    "#strong[one]",
    "#strong[two]",
})
vim.api.nvim_win_set_cursor(0, { 1, 9 })
result = typst.edit.change_function("emph", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_function failed before dot-repeat"
)

vim.api.nvim_win_set_cursor(0, { 2, 9 })
vim.cmd("normal .")
assert(
    line(2) == "#emph[two]",
    "buffer-local . should repeat the last Typst structural edit"
)

edit({
    "#strong[one]",
    "#strong[two]",
    "",
})
vim.api.nvim_win_set_cursor(0, { 1, 9 })
result = typst.edit.change_function("emph", { notify = false })
assert(
    result.ok,
    result.message or "Typst change_function failed before stale repeat"
)
vim.api.nvim_buf_set_text(0, 2, 0, 2, 0, { "changed" })
vim.api.nvim_win_set_cursor(0, { 2, 9 })
assert(
    not edit_repeat.repeat_last({ bufnr = 0 }),
    "stale Typst repeat should fall back to native dot"
)
assert(
    line(2) == "#strong[two]",
    "stale Typst repeat should not replay after another buffer edit"
)

rawset(vim, "notify", original_notify)
vim.cmd("qa!")
