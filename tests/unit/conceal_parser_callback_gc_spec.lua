local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local matches = require("typst.conceal.matches")

typst.reset({ force = true })
typst.setup({})
matches.reset()

local original_get_parser = vim.treesitter.get_parser
local ok, err = pcall(function()
    vim.treesitter.get_parser = function()
        error("forced parser failure")
    end

    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$ alpha $" })

    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        matches._parser_callback_count() == 1,
        "parserless conceal lookup should record fallback parser state"
    )

    matches.forget(bufnr)
    assert(
        matches._parser_callback_count() == 0,
        "forget should clear parser callback tracking"
    )

    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        matches._parser_callback_count() == 1,
        "parser callback tracking should be recreated for reset coverage"
    )

    matches.reset()
    assert(
        matches._parser_callback_count() == 0,
        "reset should clear parser callback tracking"
    )
end)

vim.treesitter.get_parser = original_get_parser
matches.reset()
assert(ok, err)
