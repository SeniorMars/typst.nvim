local matchparen = require("typst.edit.matchparen")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local transaction = require("typst.edit.transaction")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

local function trim(text)
    return (text or ""):match("^%s*(.-)%s*$")
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

    if result.ok then
        vim.notify(
            result.message or "Applied Typst transform",
            vim.log.levels.INFO,
            { title = "typst.nvim" }
        )
    else
        vim.notify(
            result.message or "Typst transform unavailable",
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
    end
end

local delimiter_aliases = {
    brace = "block",
    braces = "block",
    bracket = "content",
    brackets = "content",
    code = "block",
    dollar = "equation",
    dollars = "equation",
    math = "equation",
    paren = "group",
    parens = "group",
    parenthesis = "group",
    parentheses = "group",
    square = "content",
}

local delimiter_specs = {
    content = {
        open = "[",
        close = "]",
        label = "content brackets",
    },
    block = {
        open = "{",
        close = "}",
        label = "code block braces",
    },
    group = {
        open = "(",
        close = ")",
        label = "parentheses",
    },
    equation = {
        open = "$",
        close = "$",
        label = "equation delimiters",
    },
}

local delimiter_closers = {
    ["("] = ")",
    ["["] = "]",
    ["{"] = "}",
}

local function normalize_target(target)
    if type(target) ~= "string" then
        return nil
    end

    target = trim(target)
    if target == "" then
        return nil
    end

    return delimiter_aliases[target] or target
end

local function before_pos(row_a, col_a, row_b, col_b)
    return row_a < row_b or (row_a == row_b and col_a <= col_b)
end

local function contains_pair(pair, row, col)
    return before_pos(pair.open.row, pair.open.col, row, col)
        and before_pos(row, col, pair.close.row, pair.close.col)
end

local function pair_size(pair)
    return (pair.close.row - pair.open.row) * 100000
        + (pair.close.col - pair.open.col)
end

local function delimiter_pairs(tokens)
    local pairs = {}
    local stack = {}
    local math_open = nil

    for _, token in ipairs(tokens) do
        if token.kind == "math" then
            if math_open then
                pairs[#pairs + 1] = {
                    kind = "equation",
                    open = math_open,
                    close = token,
                }
                math_open = nil
            else
                math_open = token
            end
        elseif token.kind == "open" then
            stack[#stack + 1] = token
        elseif token.kind == "close" then
            for index = #stack, 1, -1 do
                local opener = stack[index]
                if delimiter_closers[opener.char] == token.char then
                    table.remove(stack, index)
                    pairs[#pairs + 1] = {
                        kind = ({
                            ["["] = "content",
                            ["{"] = "block",
                            ["("] = "group",
                        })[opener.char],
                        open = opener,
                        close = token,
                    }
                    break
                end
            end
        end
    end

    return pairs
end

local function find_pair(bufnr, opts)
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local best = nil

    for _, pair in ipairs(delimiter_pairs(matchparen.collect_tokens(bufnr))) do
        if
            contains_pair(pair, pos[1], pos[2])
            and (not best or pair_size(pair) < pair_size(best))
        then
            best = pair
        end
    end

    return best
end

local function set_pair_text(bufnr, pair, spec)
    local lines = vim.api.nvim_buf_get_text(
        bufnr,
        pair.open.row,
        pair.open.end_col,
        pair.close.row,
        pair.close.col,
        {}
    )
    if #lines == 0 then
        lines = { "" }
    end

    lines[1] = spec.open .. lines[1]
    lines[#lines] = lines[#lines] .. spec.close
    vim.api.nvim_buf_set_text(
        bufnr,
        pair.open.row,
        pair.open.col,
        pair.close.row,
        pair.close.end_col,
        lines
    )
end

local function delete_pair_text(bufnr, pair)
    if pair.open.row == pair.close.row then
        vim.api.nvim_buf_set_text(
            bufnr,
            pair.close.row,
            pair.close.col,
            pair.close.row,
            pair.close.end_col,
            { "" }
        )
        transaction.undojoin()
        vim.api.nvim_buf_set_text(
            bufnr,
            pair.open.row,
            pair.open.col,
            pair.open.row,
            pair.open.end_col,
            { "" }
        )
        return
    end

    vim.api.nvim_buf_set_text(
        bufnr,
        pair.close.row,
        pair.close.col,
        pair.close.row,
        pair.close.end_col,
        { "" }
    )
    transaction.undojoin()
    vim.api.nvim_buf_set_text(
        bufnr,
        pair.open.row,
        pair.open.col,
        pair.open.row,
        pair.open.end_col,
        { "" }
    )
end

function M.change(target, opts)
    opts = opts or {}
    target = normalize_target(target)
    local spec = target and delimiter_specs[target]
    if not spec then
        local result = err(
            "invalid_delimiter",
            'Typst delimiter target must be "content", "block", "group", or "equation"'
        )
        notify_result(result, opts)
        return result
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local pair = find_pair(bufnr, opts)
    if not pair then
        local result =
            err("no_delimiter", "No surrounding Typst delimiter pair found")
        notify_result(result, opts)
        return result
    end

    if pair.kind == target then
        local result = err(
            "already_delimiter",
            ("The surrounding Typst delimiter is already %s"):format(spec.label)
        )
        notify_result(result, opts)
        return result
    end

    set_pair_text(bufnr, pair, spec)

    local result = ok({
        action = "change_delimiter",
        message = ("Changed Typst delimiter to %s"):format(spec.label),
        target = target,
        previous = pair.kind,
    })
    edit_repeat.set((":TypstChangeDelimiter %s<CR>"):format(target))
    notify_result(result, opts)
    return result
end

function M.delete(target, opts)
    opts = opts or {}
    target = normalize_target(target or "")
    if target and not delimiter_specs[target] then
        local result = err(
            "invalid_delimiter",
            'Typst delimiter target must be "content", "block", "group", or "equation"'
        )
        notify_result(result, opts)
        return result
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local pair = find_pair(bufnr, opts)
    if not pair then
        local result =
            err("no_delimiter", "No surrounding Typst delimiter pair found")
        notify_result(result, opts)
        return result
    end

    if target and pair.kind ~= target then
        local result = err(
            "wrong_delimiter",
            ("The surrounding Typst delimiter is not %s"):format(
                delimiter_specs[target].label
            )
        )
        notify_result(result, opts)
        return result
    end

    delete_pair_text(bufnr, pair)
    local result = ok({
        action = "delete_delimiter",
        message = "Deleted surrounding Typst delimiter pair",
        previous = pair.kind,
    })
    edit_repeat.set(":TypstSurroundDeleteDelimiter<CR>")
    notify_result(result, opts)
    return result
end

return M
