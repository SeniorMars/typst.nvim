local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local conceal = require("typst.conceal")
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

local register_calls = 0
local registered_callbacks = nil
local fake_parser = {
    register_cbs = function(_, callbacks)
        register_calls = register_calls + 1
        registered_callbacks = callbacks
    end,
    parse = function()
        return {}
    end,
}

ok, err = pcall(function()
    vim.treesitter.get_parser = function()
        return fake_parser
    end

    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$ beta $" })

    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    local first_register_calls = register_calls
    assert(
        first_register_calls > 0,
        "first conceal lookup should register parser callbacks"
    )
    assert(
        matches._parser_callback_count() == 1,
        "active parser callback tracking should be visible"
    )

    matches.reset()
    assert(
        matches._parser_callback_count() == 0,
        "reset should clear active parser callback tracking"
    )
    assert(
        matches._parser_registration_count() == 1,
        "reset should retain stable parser registrations to avoid stacking"
    )

    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        register_calls == first_register_calls,
        "reset and re-enable should not stack parser callbacks"
    )
    assert(
        matches._parser_callback_count() == 1,
        "parser tracking should be restored without re-registering"
    )

    matches.forget(bufnr)
    assert(
        matches._parser_registration_count() == 1,
        "cache forget should keep stable parser registration for a live parser"
    )
    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        register_calls == first_register_calls,
        "cache forget should not stack parser callbacks while parser is alive"
    )
    assert(
        matches._parser_callback_count() == 1,
        "parser tracking should be restored after cache forget without re-registering"
    )

    assert(
        type(registered_callbacks.on_detach) == "function",
        "fake parser should capture on_detach callback"
    )
    registered_callbacks.on_detach(bufnr)
    assert(
        matches._parser_registration_count() == 0,
        "parser detach should clear stable parser registration"
    )
    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        register_calls > first_register_calls,
        "parser detach should allow registration on the next parser lifecycle"
    )
    assert(
        matches._parser_registration_count() == 1,
        "next parser lifecycle should restore stable parser registration"
    )

    conceal.detach(bufnr)
    assert(
        matches._parser_registration_count() == 1,
        "conceal detach should keep stable parser registration for a live parser"
    )
    local live_detach_register_calls = register_calls
    matches.matches(bufnr, { start_row = 0, end_row = 1 })
    assert(
        register_calls == live_detach_register_calls,
        "conceal detach should not stack callbacks while the parser is alive"
    )
    registered_callbacks.on_detach(bufnr)
    assert(
        matches._parser_registration_count() == 0,
        "parser detach should release stable parser registration"
    )

    vim.cmd.enew()
    local deleted_bufnr = vim.api.nvim_get_current_buf()
    vim.bo[deleted_bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(deleted_bufnr, 0, -1, false, { "$ gamma $" })
    matches.matches(deleted_bufnr, { start_row = 0, end_row = 1 })
    assert(
        matches._parser_registration_count() == 1,
        "deleted-buffer setup should register parser callbacks"
    )
    vim.api.nvim_buf_delete(deleted_bufnr, { force = true })
    require("typst.core.cache_registry").forget_buffer(deleted_bufnr)
    assert(
        matches._parser_registration_count() == 0,
        "cache registry buffer forget should release parser registrations for invalid buffers"
    )
end)

vim.treesitter.get_parser = original_get_parser
matches.reset()
assert(ok, err)
