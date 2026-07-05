local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-reveal-render-output"),
})
local matches = require("typst.conceal.matches")
local render = require("typst.conceal.render")
local reveal = require("typst.conceal.reveal")

local function match_at(text, start_col, end_col)
    return {
        source = {
            start_row = 0,
            start_col = start_col,
            end_row = 0,
            end_col = end_col,
        },
        reveal = {
            start_row = 0,
            start_col = start_col,
            end_row = 0,
            end_col = end_col,
        },
        source_text = text,
        replacement = "*",
        category = "math_symbols",
    }
end

local left = match_at("alpha", 2, 7)
local right = match_at("beta", 10, 14)

assert(
    reveal.should_reveal(left, { reveal = "node" }, 0, 3),
    "node reveal should reveal match under cursor"
)
assert(
    not reveal.should_reveal(right, { reveal = "node" }, 0, 3),
    "node reveal should not reveal neighboring same-line matches"
)
assert(
    reveal.should_reveal(right, { reveal = "line" }, 0, 3),
    "line reveal should reveal all matches on cursor line"
)
local trailing_empty_line = {
    source = {
        start_row = 0,
        start_col = 2,
        end_row = 1,
        end_col = 0,
    },
    reveal = {
        start_row = 0,
        start_col = 2,
        end_row = 1,
        end_col = 0,
    },
    category = "math_symbols",
}
assert(
    not reveal.should_reveal(trailing_empty_line, { reveal = "line" }, 1, 0),
    "line reveal should not reveal an empty trailing end row"
)
assert(
    not reveal.should_reveal(left, { reveal = "none" }, 0, 3),
    "none reveal should never reveal source"
)
assert(not reveal.should_reveal(left, {
    reveal = "line",
    reveal_by_category = { math_symbols = "none" },
}, 0, 3), "category reveal policy should override the default policy")

local original_mode = vim.api.nvim_get_mode
rawset(vim.api, "nvim_get_mode", function()
    return { mode = "i" }
end)
assert(
    not reveal.should_reveal(
        left,
        { reveal = "node", reveal_insert = "none" },
        0,
        3
    ),
    "insert-mode reveal policy should be respected"
)
vim.api.nvim_get_mode = original_mode

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$ alpha + beta $" })
vim.bo[bufnr].filetype = "typst"
local winid = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
local old_matches = matches.matches
local calls = 0
rawset(matches, "matches", function()
    calls = calls + 1
    return { left, right }
end)
render.reset()
local first = render.window_matches(bufnr, winid, {
    start_row = 0,
    end_row = 1,
    conceal_opts = { reveal = "none" },
}, {})
vim.api.nvim_win_set_cursor(winid, { 1, 12 })
local second = render.window_matches(bufnr, winid, {
    start_row = 0,
    end_row = 1,
    conceal_opts = { reveal = "none" },
}, {})
assert(
    #first == 2 and #second == 2,
    "render cache should keep collected matches"
)
assert(
    calls == 1,
    "cursor movement in the same viewport should reuse collected matches"
)

local old_tbl_keys = vim.tbl_keys
rawset(vim, "tbl_keys", function()
    error("render cache hot path should not recursively signature tables")
end)
local ok_hot_path, hot_path = pcall(function()
    return render.window_matches(bufnr, winid, {
        start_row = 0,
        end_row = 1,
        conceal_opts = { reveal = "none" },
    }, { math = { alpha = "*" } })
end)
vim.tbl_keys = old_tbl_keys
assert(ok_hot_path, hot_path)
assert(
    #hot_path == 2 and calls == 1,
    "render cache hits should use generation counters instead of table walks"
)

render.reset()
local third = render.window_matches(bufnr, winid, {
    start_row = 0,
    end_row = 1,
    conceal_opts = { reveal = "none" },
}, {})
assert(#third == 2 and calls == 2, "render reset should drop per-window cache")

matches.matches = old_matches

vim.cmd("qa!")
