local M = {}
local edit_context = require("typst.edit.context")
local lexical = require("typst.syntax.lexical")

local bracket_pairs = {
    ["("] = ")",
    ["["] = "]",
    ["{"] = "}",
}

local closing_pairs = {
    [")"] = "(",
    ["]"] = "[",
    ["}"] = "{",
}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_context(opts, bufnr)
    if opts.cursor then
        local ctx = edit_context.resolve(opts, { require_position = false })
        return opts.cursor, ctx
    end

    local ctx = edit_context.resolve(
        vim.tbl_extend("force", opts or {}, { bufnr = bufnr }),
        { require_position = true }
    )
    if not ctx then
        return nil, nil
    end
    return { ctx.row + 1, ctx.col }, ctx
end

local function raw_fence(line)
    local indent, ticks = lexical.raw_fence_marker(line)
    if not ticks then
        return nil
    end

    return #indent, ticks
end

local function add_token(tokens, token)
    token.index = #tokens + 1
    tokens[#tokens + 1] = token
end

local function scan_line(tokens, line, row)
    local code_line = lexical.mask_line(line, {
        strings = "space",
        comments = "space",
        raw = "space",
    })

    for index = 1, #code_line do
        local char = code_line:sub(index, index)
        local kind = bracket_pairs[char] and "open"
            or closing_pairs[char] and "close"
            or (char == "$" and not lexical.is_escaped(code_line, index))
                and "math"
        if kind then
            add_token(tokens, {
                kind = kind,
                char = char,
                row = row,
                col = index - 1,
                end_col = index,
            })
        end
    end
end

local function collect_tokens(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local tokens = {}
    local in_raw = nil

    for row, line in ipairs(lines) do
        row = row - 1
        local fence_col, ticks = raw_fence(line)
        if in_raw then
            if fence_col and #ticks == #in_raw.ticks then
                add_token(tokens, {
                    kind = "raw_fence",
                    char = ticks,
                    row = row,
                    col = fence_col,
                    end_col = fence_col + #ticks,
                    match_index = in_raw.index,
                })
                tokens[in_raw.index].match_index = #tokens
                in_raw = nil
            end
        elseif fence_col then
            add_token(tokens, {
                kind = "raw_fence",
                char = ticks,
                row = row,
                col = fence_col,
                end_col = fence_col + #ticks,
            })
            in_raw = {
                index = #tokens,
                ticks = ticks,
            }
        else
            scan_line(tokens, line, row)
        end
    end

    return tokens
end

local function token_at_or_after(tokens, row, col)
    local fallback = nil
    for _, token in ipairs(tokens) do
        if token.row == row and col >= token.col and col < token.end_col then
            return token
        end

        if token.row == row and token.col >= col and not fallback then
            fallback = token
        end
    end
    return fallback
end

local function math_match(tokens, token)
    local math_tokens = {}
    for _, candidate in ipairs(tokens) do
        if candidate.kind == "math" then
            math_tokens[#math_tokens + 1] = candidate
        end
    end

    for index, candidate in ipairs(math_tokens) do
        if candidate == token then
            if index % 2 == 1 then
                return math_tokens[index + 1]
            end
            return math_tokens[index - 1]
        end
    end
end

local function bracket_match(tokens, token)
    local opener = token.kind == "open" and token.char
        or closing_pairs[token.char]
    local closer = token.kind == "open" and bracket_pairs[token.char]
        or token.char
    local depth = 0

    if token.kind == "open" then
        for index = token.index + 1, #tokens do
            local candidate = tokens[index]
            if candidate.char == opener then
                depth = depth + 1
            elseif candidate.char == closer then
                if depth == 0 then
                    return candidate
                end
                depth = depth - 1
            end
        end
        return nil
    end

    for index = token.index - 1, 1, -1 do
        local candidate = tokens[index]
        if candidate.char == closer then
            depth = depth + 1
        elseif candidate.char == opener then
            if depth == 0 then
                return candidate
            end
            depth = depth - 1
        end
    end
end

local function find_match(tokens, token)
    if not token then
        return nil
    end

    if token.kind == "raw_fence" then
        return token.match_index and tokens[token.match_index] or nil
    end

    if token.kind == "math" then
        return math_match(tokens, token)
    end

    if token.kind == "open" or token.kind == "close" then
        return bracket_match(tokens, token)
    end
end

function M.target(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local cursor, ctx = cursor_context(opts, bufnr)
    if not cursor then
        return nil
    end
    local row = cursor[1] - 1
    local col = cursor[2]
    local tokens = collect_tokens(bufnr)
    local token = token_at_or_after(tokens, row, col)
    local match = find_match(tokens, token)

    if not match then
        return nil
    end

    return {
        row = match.row,
        col = match.col,
        token = token,
        match = match,
        context = ctx,
    }
end

function M.jump(opts)
    opts = opts or {}
    local target = M.target(opts)
    if not target then
        if opts.notify ~= false then
            vim.notify(
                "No matching Typst delimiter found",
                vim.log.levels.WARN,
                { title = "typst.nvim" }
            )
        end
        return false
    end

    if target.context then
        return edit_context.set_cursor(target.context, target.row, target.col)
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local winid = edit_context.window_for_buffer(bufnr, opts)
    if not winid then
        return false
    end
    vim.api.nvim_win_set_cursor(winid, { target.row + 1, target.col })
    return true
end

M.collect_tokens = collect_tokens

return M
