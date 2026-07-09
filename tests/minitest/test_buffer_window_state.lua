local MiniTest = require("mini.test")

local helpers = require("tests.minitest.helpers")

local T = MiniTest.new_set()

local function position_resolution_contract()
    local position = require("typst.completion.position")
    local coordinates = require("typst.core.coordinates")
    local context_core = require("typst.ui.context_menu_core")

    local current = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(current)
    vim.api.nvim_buf_set_lines(current, 0, -1, false, {
        "#let current = 1",
    })
    vim.bo[current].filetype = "typst"
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    local current_win = vim.api.nvim_get_current_win()

    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, {
        "#let other = 1",
        "#let target = 2",
    })
    vim.bo[other].filetype = "typst"
    vim.cmd("botright split")
    local other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other_win, other)
    vim.api.nvim_win_set_cursor(other_win, { 2, 4 })
    vim.api.nvim_set_current_win(current_win)

    assert(
        position.resolve({ bufnr = other }) == nil,
        "explicit noncurrent buffer should require opts.pos or opts.winid"
    )

    local explicit_pos = assert(position.resolve({
        bufnr = other,
        pos = { 1, 4 },
    }))
    assert(
        explicit_pos.bufnr == other
            and explicit_pos.row == 1
            and explicit_pos.col == 4,
        "explicit opts.pos should resolve for noncurrent buffers"
    )

    local explicit_window = assert(position.resolve({
        bufnr = other,
        winid = other_win,
    }))
    assert(
        explicit_window.bufnr == other
            and explicit_window.row == 1
            and explicit_window.col == 4,
        "explicit opts.winid should resolve for noncurrent buffers"
    )

    assert(
        context_core.current_context_pos({ bufnr = other }) == nil,
        "context helpers should not fall back to noncurrent window cursor"
    )

    local context_pos = context_core.current_context_pos({
        bufnr = other,
        pos = { 1, 4 },
    })
    assert(
        context_pos and context_pos[1] == 1 and context_pos[2] == 4,
        "context helpers should accept explicit noncurrent opts.pos"
    )

    local unicode = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(unicode, 0, -1, false, {
        "é α 中 😀 é\t@label",
    })
    vim.bo[unicode].filetype = "typst"
    local mixed_line = coordinates.line_text(unicode, 0)
    local label_byte_col = assert(
        mixed_line:find("@label", 1, true),
        "Unicode coordinate fixture should contain a label"
    ) - 1
    local utf16_character = coordinates.byte_col_to_lsp_character(
        unicode,
        0,
        label_byte_col,
        "utf-16"
    )
    assert(
        utf16_character == 11,
        "UTF-8 byte columns should convert to UTF-16 LSP characters at boundaries"
    )
    assert(
        coordinates.buffer_lsp_character_to_byte_col(
            unicode,
            0,
            utf16_character,
            "utf-16"
        ) == label_byte_col,
        "UTF-16 LSP characters should round-trip to internal byte columns"
    )
    assert(
        coordinates.byte_col_to_lsp_character(
            unicode,
            0,
            label_byte_col,
            "utf-8"
        ) == label_byte_col,
        "UTF-8 LSP clients should receive the internal byte column unchanged"
    )
end

T["resolves positions without stealing window context"] = function()
    helpers.start_child().lua_func(position_resolution_contract)
end

return T
