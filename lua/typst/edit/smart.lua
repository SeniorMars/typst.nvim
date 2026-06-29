local edit_repeat = require("typst.edit.repeat")
local cursor = require("typst.edit.cursor")
local edit_context = require("typst.edit.context")
local lexical = require("typst.syntax.lexical")

local M = {}

-- Small local transforms for common Typst edits. These intentionally stay
-- conservative and line-oriented; more semantic rewrites should go through
-- Tinymist structural actions instead of growing parser logic here.

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_pos(bufnr, opts)
    return cursor.row_col(bufnr, opts)
end

local function cursor_row(opts, bufnr)
    if type(opts.row) == "number" then
        return opts.row
    end
    return select(1, cursor_pos(bufnr, opts))
end

local function cursor_col(opts, bufnr)
    if type(opts.col) == "number" then
        return opts.col
    end
    return select(2, cursor_pos(bufnr, opts))
end

local function ok(result)
    result.ok = true
    return result
end

local function err(reason, message)
    return {
        ok = false,
        reason = reason,
        message = message,
    }
end

local function notify_result(result, opts)
    if opts and opts.notify == false then
        return
    end

    vim.notify(
        result.message
            or (
                result.ok and "Applied Typst transform"
                or "Typst transform unavailable"
            ),
        result.ok and vim.log.levels.INFO or vim.log.levels.WARN,
        { title = "typst.nvim" }
    )
end

local function line_at(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function replace_line_range(bufnr, row, start_col, end_col, text)
    vim.api.nvim_buf_set_text(bufnr, row, start_col, row, end_col, { text })
end

local function find_first(line, pattern)
    local start_col, end_col, one, two = line:find(pattern)
    if not start_col then
        return nil
    end
    return {
        start_col = start_col - 1,
        end_col = end_col,
        one = one,
        two = two,
    }
end

function M.toggle_fraction(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local row = cursor_row(opts, bufnr)
    if not row then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local line = line_at(bufnr, row)

    local call =
        find_first(line, "frac%(%s*([^,\n%(%)]+)%s*,%s*([^\n%(%)]+)%s*%)")
    if call then
        local replacement = ("%s / %s"):format(
            vim.trim(call.one),
            vim.trim(call.two)
        )
        replace_line_range(
            bufnr,
            row,
            call.start_col,
            call.end_col,
            replacement
        )
        local result = ok({
            action = "toggle_fraction",
            style = "slash",
            message = "Converted frac(...) to slash form",
        })
        edit_repeat.set(":TypstToggleFraction<CR>")
        notify_result(result, opts)
        return result
    end

    local slash = find_first(line, "([%w_%.%-]+)%s*/%s*([%w_%.%-]+)")
    if slash then
        local replacement = ("frac(%s, %s)"):format(slash.one, slash.two)
        replace_line_range(
            bufnr,
            row,
            slash.start_col,
            slash.end_col,
            replacement
        )
        local result = ok({
            action = "toggle_fraction",
            style = "function",
            message = "Converted slash form to frac(...)",
        })
        edit_repeat.set(":TypstToggleFraction<CR>")
        notify_result(result, opts)
        return result
    end

    local result = err(
        "no_fraction",
        "No simple Typst fraction form found on the current line"
    )
    notify_result(result, opts)
    return result
end

function M.toggle_delimiter_size(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local row = cursor_row(opts, bufnr)
    if not row then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local line = line_at(bufnr, row)

    local sized = find_first(line, "lr%(%s*(.-)%s*%)")
    if sized and sized.one and sized.one ~= "" then
        replace_line_range(
            bufnr,
            row,
            sized.start_col,
            sized.end_col,
            ("(%s)"):format(vim.trim(sized.one))
        )
        local result = ok({
            action = "toggle_delimiter_size",
            style = "plain",
            message = "Converted lr(...) to plain delimiters",
        })
        edit_repeat.set(":TypstToggleDelimiterSize<CR>")
        notify_result(result, opts)
        return result
    end

    local plain = find_first(line, "%(([^%(%)]+)%)")
    if plain then
        replace_line_range(
            bufnr,
            row,
            plain.start_col,
            plain.end_col,
            ("lr(%s)"):format(vim.trim(plain.one))
        )
        local result = ok({
            action = "toggle_delimiter_size",
            style = "lr",
            message = "Converted plain delimiters to lr(...)",
        })
        edit_repeat.set(":TypstToggleDelimiterSize<CR>")
        notify_result(result, opts)
        return result
    end

    local result = err(
        "no_delimiter",
        "No simple Typst delimiter form found on the current line"
    )
    notify_result(result, opts)
    return result
end

function M.toggle_line_break(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local row = cursor_row(opts, bufnr)
    if not row then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local line = line_at(bufnr, row)
    local replacement
    local enabled

    if line:match("\\%s*$") then
        replacement = line:gsub("%s*\\%s*$", "")
        enabled = false
    else
        replacement = line:gsub("%s*$", "") .. " \\"
        enabled = true
    end

    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { replacement })
    local result = ok({
        action = "toggle_line_break",
        enabled = enabled,
        message = enabled and "Added Typst line break"
            or "Removed Typst line break",
    })
    edit_repeat.set(":TypstToggleLineBreak<CR>")
    notify_result(result, opts)
    return result
end

local function selected_rows(bufnr, opts)
    if
        type(opts.line1) == "number"
        and type(opts.line2) == "number"
        and opts.range
        and opts.range > 0
    then
        return opts.line1 - 1, opts.line2 - 1
    end
    local row = cursor_row(opts, bufnr)
    return row, row
end

local function validate_function_name(name)
    if type(name) ~= "string" or vim.trim(name) == "" then
        return nil
    end
    name = vim.trim(name):gsub("^#", "")
    if not name:match("^[%a_][%w_%-%.]*$") or name:find("%.%.", 1, true) then
        return nil
    end
    return name
end

function M.create_function(name, opts)
    opts = opts or {}
    name = validate_function_name(name)
    if not name then
        local result = err(
            "invalid_name",
            "Typst function name must be a valid identifier or path"
        )
        notify_result(result, opts)
        return result
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local start_row, end_row = selected_rows(bufnr, opts)
    if not start_row or not end_row then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local lines =
        vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    if #lines == 0 then
        local result = err(
            "empty_range",
            "No Typst content selected for function creation"
        )
        notify_result(result, opts)
        return result
    end

    if #lines == 1 then
        local line = lines[1]
        local col = cursor_col(opts, bufnr)
        if not col then
            local result =
                err("position_required", "No Typst cursor position found")
            notify_result(result, opts)
            return result
        end
        local start_col = col + 1
        while
            start_col > 1
            and line:sub(start_col - 1, start_col - 1):match("[%w_%-]")
        do
            start_col = start_col - 1
        end
        local end_col = col + 1
        while
            end_col <= #line and line:sub(end_col, end_col):match("[%w_%-]")
        do
            end_col = end_col + 1
        end
        if start_col <= #line and end_col > start_col then
            local word = line:sub(start_col, end_col - 1)
            replace_line_range(
                bufnr,
                start_row,
                start_col - 1,
                end_col - 1,
                ("#%s(%s)"):format(name, word)
            )
        else
            vim.api.nvim_buf_set_lines(
                bufnr,
                start_row,
                end_row + 1,
                false,
                { ("#%s(%s)"):format(name, vim.trim(line)) }
            )
        end
    else
        lines[1] = ("#%s["):format(name) .. lines[1]
        lines[#lines] = lines[#lines] .. "]"
        vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, lines)
    end

    local result = ok({
        action = "create_function",
        name = name,
        message = ("Created Typst function call #%s"):format(name),
    })
    edit_repeat.set((":TypstCreateFunction %s<CR>"):format(name))
    notify_result(result, opts)
    return result
end

function M.smart_close(opts)
    opts = opts or {}
    local ctx = edit_context.resolve(opts)
    if not ctx then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local bufnr = ctx.bufnr
    local row, col = ctx.row, ctx.col

    local line = ctx.line or line_at(bufnr, row)
    local cursor_char = line:sub(col + 1, col + 1)
    local before = line:sub(1, math.max(col + 1, 1))
    local masked = lexical.mask_line(before, {
        strings = "space",
        raw = "space",
        comments = "space",
    })
    -- Only scan the visible code before the cursor. Closing a delimiter from a
    -- string/comment/raw span would insert syntax where the user is editing text.
    local stack = {}
    local closers = {
        ["("] = ")",
        ["["] = "]",
        ["{"] = "}",
        ["$"] = "$",
        ["`"] = "`",
    }
    local openers = {
        [")"] = "(",
        ["]"] = "[",
        ["}"] = "{",
    }

    for index = 1, #masked do
        local char = masked:sub(index, index)
        if closers[char] then
            if char == "$" and stack[#stack] == "$" then
                stack[#stack] = nil
            else
                stack[#stack + 1] = char
            end
        elseif openers[char] and stack[#stack] == openers[char] then
            stack[#stack] = nil
        end
    end

    local opener = stack[#stack]
    local closer = opener and closers[opener]
    if not closer then
        local result = err(
            "no_open_delimiter",
            "No unmatched Typst delimiter found before the cursor"
        )
        notify_result(result, opts)
        return result
    end

    local insert_col = closers[cursor_char] and col + 1 or col
    vim.api.nvim_buf_set_text(
        bufnr,
        row,
        insert_col,
        row,
        insert_col,
        { closer }
    )
    local cursor_moved =
        edit_context.set_cursor(ctx, row, math.max(insert_col - 1, 0))
    local result = ok({
        action = "smart_close",
        bufnr = bufnr,
        closer = closer,
        row = row,
        col = math.max(insert_col - 1, 0),
        cursor_moved = cursor_moved,
        message = ("Inserted %s"):format(closer),
    })
    notify_result(result, opts)
    return result
end

return M
