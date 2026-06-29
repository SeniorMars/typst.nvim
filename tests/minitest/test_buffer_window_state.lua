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

local function eval_selection_contract()
    local root = vim.fn.getcwd()

    local eval_workflow = require("typst.workflows.eval")
    local typst = require("typst")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("eval-selection-output"),
    })

    local captured = {}
    typst.providers.register("eval", "eval-selection-capture", {
        eval = function(_, opts)
            captured[#captured + 1] = opts.expression
            return {
                ok = true,
                expression = opts.expression,
            }
        end,
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local current_buf = vim.api.nvim_get_current_buf()
    local current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, { "current" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[target_buf].filetype = "typst"
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, {
        "target-one",
        "target-two",
    })

    local missing_position = eval_workflow.eval_selection(project, {
        bufnr = target_buf,
        provider = "eval-selection-capture",
    })
    assert(
        not missing_position.ok
            and missing_position.reason == "position_required",
        "non-current eval selection should require an explicit range or target window"
    )
    assert(
        captured[1] == nil,
        "failed eval selection should not invoke the provider"
    )

    local explicit_range = eval_workflow.eval_selection(project, {
        bufnr = target_buf,
        line1 = 2,
        line2 = 2,
        provider = "eval-selection-capture",
    })
    assert(
        explicit_range.ok,
        "explicit target-buffer eval range should succeed"
    )
    assert(
        captured[1] == "target-two",
        "eval selection should read explicit ranges from the target buffer"
    )

    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
    vim.api.nvim_set_current_win(current_win)

    local window_range = eval_workflow.eval_selection(project, {
        bufnr = target_buf,
        winid = target_win,
        provider = "eval-selection-capture",
    })
    assert(window_range.ok, "target-window eval selection should succeed")
    assert(
        captured[2] == "target-one",
        "eval selection should use a supplied window only when it displays the target buffer"
    )
    assert(
        vim.api.nvim_get_current_buf() == current_buf,
        "target-window eval selection should not switch the current buffer"
    )
end

T["resolves positions without stealing window context"] = function()
    helpers.start_child().lua_func(position_resolution_contract)
end

T["evaluates selections from explicit buffers and windows"] = function()
    helpers.start_child().lua_func(eval_selection_contract)
end

return T
