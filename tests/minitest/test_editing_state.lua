local MiniTest = require("mini.test")

local helpers = require("tests.minitest.helpers")

local T = MiniTest.new_set()

local function insert_helpers_contract()
    local root = vim.fn.getcwd()
    vim.opt.showmode = false

    local typst = require("typst")
    typst.reset()
    typst.setup({
        root = root,
        mappings = {
            insert = {
                math = "<M-m>",
            },
        },
    })
    local function reset_buffer(line, col)
        vim.cmd("enew!")
        vim.bo.filetype = "typst"
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { line or "" })
        vim.api.nvim_win_set_cursor(0, { 1, col or 0 })
    end

    local function line()
        return vim.api.nvim_get_current_line()
    end

    reset_buffer("")
    local strong = typst.edit.insert_strong()
    assert(
        strong.ok and strong.kind == "strong",
        "insert_strong should report the inserted helper"
    )
    assert(line() == "**", "insert_strong should insert paired strong markup")
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 1,
        "insert_strong should place the cursor between markers"
    )

    reset_buffer("")
    local emph = typst.edit.insert("italic")
    assert(
        emph.kind == "emph",
        "insert aliases should resolve to canonical kinds"
    )
    assert(line() == "__", "insert emph should insert paired emphasis markup")
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 1,
        "insert emph should place the cursor between markers"
    )

    reset_buffer("")
    local math = typst.edit.insert_math()
    assert(
        math.ok and math.kind == "math",
        "insert_math should report math kind"
    )
    assert(
        line() == "$  $",
        "insert_math should insert Typst inline equation delimiters"
    )
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 2,
        "insert_math should place the cursor inside the equation"
    )

    reset_buffer("abc", 1)
    typst.edit.insert_content()
    assert(line() == "a[]bc", "insert_content should insert at the cursor")
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 2,
        "insert_content should place the cursor between brackets"
    )

    reset_buffer("")
    typst.edit.insert_code()
    assert(line() == "#{}", "insert_code should insert a Typst code expression")
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 2,
        "insert_code should place the cursor inside braces"
    )

    reset_buffer("")
    vim.cmd("TypstInsert raw")
    assert(line() == "``", "TypstInsert should call the insert helper")
    assert(
        vim.api.nvim_win_get_cursor(0)[2] == 1,
        "TypstInsert should place the cursor inside raw delimiters"
    )

    local current_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, { "current" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local current_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "target" })
    local targeted = typst.edit.insert_math({
        bufnr = target_buf,
        row = 0,
        col = 0,
    })
    assert(targeted.ok, targeted.message or "targeted insert should succeed")
    assert(
        vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)[1] == "$  $target",
        "insert_math should target explicit buffers"
    )
    assert(
        vim.api.nvim_get_current_buf() == current_buf
            and vim.api.nvim_win_get_cursor(current_win)[2] == 0,
        "targeted insert should not move the unrelated current window"
    )

    reset_buffer("")
    vim.keymap.set(
        "i",
        "<F5>",
        "<Plug>(typst-insert-math)",
        { buffer = 0, remap = true }
    )
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("i<F5><Esc>", true, false, true),
        "xt",
        false
    )
    assert(
        line() == "$  $",
        "insert-mode plug mapping should insert paired markup"
    )

    local ok, err = pcall(function()
        typst.edit.insert("unknown")
    end)
    assert(
        not ok and tostring(err):match("unknown insert helper"),
        "unknown insert helpers should fail clearly"
    )

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    assert(typst.project.attach(0), "Typst attach should succeed")
    local mapped = vim.fn.maparg("<M-m>", "i", false, true)
    assert(
        type(mapped) == "table" and mapped.rhs == "<Plug>(typst-insert-math)",
        "configured insert map should be buffer-local"
    )
end

local function matchparen_contract()
    local root = vim.fn.getcwd()

    local typst = require("typst")
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("matchparen-output"),
    })
    local original_notify = vim.notify
    rawset(vim, "notify", function() end)

    local ok, err = xpcall(function()
        local main = root .. "/tests/fixtures/basic/editing.typ"
        vim.cmd.edit(main)
        vim.bo.filetype = "typst"
        typst.project.attach(0)

        assert(
            vim.fn.maparg("%", "n") == "<Plug>(typst-match)",
            "default % mapping should use Typst matcher"
        )

        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "#figure(",
            "  [Hi],",
            "  caption: [",
            "    Cap",
            "  ],",
            ")",
            "$ x + y $",
            "$",
            "  a = b",
            "$",
            "```typst",
            "#let z = (3)",
            "```",
            "Don't hide (value)",
            "Price \\$5 and $ a $",
        })
        local matchparen = require("typst.edit.matchparen")

        vim.api.nvim_win_set_cursor(0, { 1, 7 })
        assert(
            matchparen.jump({ notify = false }),
            "opening group delimiter should match"
        )
        local cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 6 and cursor[2] == 0,
            "opening group should jump to closing group"
        )

        assert(
            matchparen.jump({ notify = false }),
            "closing group delimiter should match"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 1 and cursor[2] == 7,
            "closing group should jump back to opening group"
        )

        vim.api.nvim_win_set_cursor(0, { 3, 11 })
        assert(
            typst.edit.match({ notify = false }),
            "content delimiter should match through public API"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 5 and cursor[2] == 2,
            "content delimiter should jump to matching bracket"
        )

        vim.api.nvim_win_set_cursor(0, { 7, 0 })
        assert(
            matchparen.jump({ notify = false }),
            "inline math delimiter should match"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 7 and cursor[2] == 8,
            "inline math should jump to closing dollar"
        )

        vim.api.nvim_win_set_cursor(0, { 8, 0 })
        assert(
            matchparen.jump({ notify = false }),
            "display math fence should match"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 10 and cursor[2] == 0,
            "display math should jump to closing dollar"
        )

        vim.api.nvim_win_set_cursor(0, { 11, 0 })
        assert(
            matchparen.jump({ notify = false }),
            "raw block fence should match"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 13 and cursor[2] == 0,
            "raw block should jump to closing fence"
        )

        vim.api.nvim_win_set_cursor(0, { 12, 10 })
        assert(
            not matchparen.jump({ notify = false }),
            "raw block contents should not expose delimiter matches"
        )

        vim.api.nvim_win_set_cursor(0, { 14, #"Don't hide " })
        assert(
            matchparen.jump({ notify = false }),
            "contractions should not hide later delimiters"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 14 and cursor[2] == #"Don't hide (value",
            "delimiter after contraction should match"
        )

        vim.api.nvim_win_set_cursor(0, { 15, #"Price \\$5 and " })
        assert(
            matchparen.jump({ notify = false }),
            "escaped literal dollars should not shift equation matching"
        )
        cursor = vim.api.nvim_win_get_cursor(0)
        assert(
            cursor[1] == 15 and cursor[2] == #"Price \\$5 and $ a ",
            "math after escaped dollar should match"
        )

        local current_win = vim.api.nvim_get_current_win()
        local current_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_cursor(current_win, { 1, 0 })
        local target_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[target_buf].filetype = "typst"
        vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "(target)" })
        vim.cmd("vsplit")
        local target_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(target_win, target_buf)
        vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
        vim.api.nvim_set_current_win(current_win)
        assert(
            matchparen.jump({
                bufnr = target_buf,
                winid = target_win,
                notify = false,
            }),
            "targeted matchparen jump should use the supplied window"
        )
        assert(
            vim.api.nvim_win_get_cursor(target_win)[2] == #"target" + 1,
            "targeted matchparen jump should move the target window"
        )
        assert(
            vim.api.nvim_get_current_buf() == current_buf
                and vim.api.nvim_win_get_cursor(current_win)[2] == 0,
            "targeted matchparen jump should not move the current window"
        )

        local highlight = require("typst.edit.match_highlight")
        local highlight_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(highlight_buf)
        vim.bo[highlight_buf].filetype = "typst"
        vim.api.nvim_buf_set_lines(highlight_buf, 0, -1, false, { "[alpha]" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        typst.project.attach(highlight_buf)
        assert(
            highlight.is_enabled(highlight_buf),
            "match highlighting should be enabled by default"
        )
        assert(
            highlight.refresh(highlight_buf) == 1,
            "match highlight refresh should mark the current window"
        )
        local marks = vim.api.nvim_buf_get_extmarks(
            highlight_buf,
            highlight.namespace(),
            0,
            -1,
            {}
        )
        assert(
            #marks == 2,
            "match highlight should mark both sides of the pair"
        )

        typst.match_highlight.disable(highlight_buf)
        assert(
            not highlight.is_enabled(highlight_buf),
            "match highlight disable should clear enabled state"
        )
        marks = vim.api.nvim_buf_get_extmarks(
            highlight_buf,
            highlight.namespace(),
            0,
            -1,
            {}
        )
        assert(#marks == 0, "match highlight disable should clear marks")

        typst.match_highlight.enable(highlight_buf)
        assert(
            highlight.is_enabled(highlight_buf),
            "match highlight enable should restore enabled state"
        )
        vim.cmd("TypstMatchHighlightRefresh")
        marks = vim.api.nvim_buf_get_extmarks(
            highlight_buf,
            highlight.namespace(),
            0,
            -1,
            {}
        )
        assert(
            #marks == 2,
            "TypstMatchHighlightRefresh should mark both delimiters"
        )

        vim.cmd("TypstMatchHighlightToggle")
        assert(
            not highlight.is_enabled(highlight_buf),
            "TypstMatchHighlightToggle should disable active highlighting"
        )
        vim.cmd("TypstMatchHighlightToggle")
        assert(
            highlight.is_enabled(highlight_buf),
            "TypstMatchHighlightToggle should enable inactive highlighting"
        )
    end, debug.traceback)

    rawset(vim, "notify", original_notify)

    if not ok then
        error(err)
    end
end

T["applies insert helpers and insert-mode mappings"] = function()
    helpers.start_child().lua_func(insert_helpers_contract)
end

T["jumps and highlights matching Typst delimiters"] = function()
    helpers.start_child().lua_func(matchparen_contract)
end

return T
