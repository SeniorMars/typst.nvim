local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local context = require("typst.completion.context")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain" })
local calls = 0
local callbacks = {
    parameter_value = function()
        calls = calls + 1
        return false
    end,
    parameter = function()
        calls = calls + 1
        return false
    end,
}

context.clear_cache()

local first = context.kind(bufnr, { 0, 5 }, callbacks)
assert(first == "markup", "plain text completion context should be markup")
assert(calls == 2, "first context classification should call callbacks")

local second = context.kind(bufnr, { 0, 5 }, callbacks)
assert(second == "markup", "cached context classification should match")
assert(calls == 2, "cached context classification should not recall callbacks")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain changed" })
local after_change = context.kind(bufnr, { 0, 5 }, callbacks)
assert(after_change == "markup", "changed buffer context should remain markup")
assert(calls == 4, "changedtick should invalidate completion context cache")

local other_pos = context.kind(bufnr, { 0, 6 }, callbacks)
assert(other_pos == "markup", "different position context should remain markup")
assert(calls == 6, "position changes should miss completion context cache")

vim.cmd("qa!")
