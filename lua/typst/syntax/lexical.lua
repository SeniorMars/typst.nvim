local M = {}

local lexical_context = require("typst.syntax.lexical_context")

local function replacement_mode(value, fallback)
    if value == false or value == "keep" then
        return "keep"
    end
    if value == true or value == "space" or value == nil then
        return fallback or "space"
    end
    return value
end

local function append_segment(out, text, mode)
    if mode == "keep" then
        out[#out + 1] = text
    else
        out[#out + 1] = (" "):rep(#text)
    end
end

local function mask_whole_line(line, mode)
    if mode == "keep" then
        return line
    end
    return (" "):rep(#line)
end

function M.backtick_run(line, index)
    if line:sub(index, index) ~= "`" then
        return nil
    end

    local stop = index
    while line:sub(stop + 1, stop + 1) == "`" do
        stop = stop + 1
    end
    return stop - index + 1
end

function M.raw_fence_marker(line)
    local indent, ticks = (line or ""):match("^(%s*)(`+)")
    if ticks and #ticks >= 3 then
        return indent, ticks
    end
end

function M.is_escaped(line, index)
    local backslashes = 0
    index = index - 1
    while index >= 1 and line:sub(index, index) == "\\" do
        backslashes = backslashes + 1
        index = index - 1
    end
    return backslashes % 2 == 1
end

function M.is_line_comment_start(line, index)
    if line:sub(index, index + 1) ~= "//" then
        return false
    end

    return line:sub(index - 1, index - 1) ~= ":"
end

local function mask_options(opts)
    opts = opts or {}
    return {
        strings = replacement_mode(opts.strings),
        raw = replacement_mode(opts.raw),
        line_comments = replacement_mode(
            opts.line_comments ~= nil and opts.line_comments or opts.comments
        ),
        block_comments = replacement_mode(
            opts.block_comments ~= nil and opts.block_comments or opts.comments
        ),
    }
end

function M.mask_lines(lines, opts)
    local modes = mask_options(opts)
    local masked = {}
    local block_depth = 0
    local fence = nil

    for row, line in ipairs(lines or {}) do
        local _, fence_ticks = M.raw_fence_marker(line)
        if fence then
            masked[row] = mask_whole_line(line, modes.raw)
            if fence_ticks and #fence_ticks >= #fence then
                fence = nil
            end
        elseif fence_ticks then
            masked[row] = mask_whole_line(line, modes.raw)
            fence = fence_ticks
        else
            local out = {}
            local index = 1
            local in_string = false
            local escaped = false

            while index <= #line do
                local char = line:sub(index, index)
                local next_char = line:sub(index + 1, index + 1)

                if block_depth > 0 then
                    if char == "/" and next_char == "*" then
                        block_depth = block_depth + 1
                        append_segment(
                            out,
                            line:sub(index, index + 1),
                            modes.block_comments
                        )
                        index = index + 2
                    elseif char == "*" and next_char == "/" then
                        block_depth = block_depth - 1
                        append_segment(
                            out,
                            line:sub(index, index + 1),
                            modes.block_comments
                        )
                        index = index + 2
                    else
                        append_segment(out, char, modes.block_comments)
                        index = index + 1
                    end
                elseif in_string then
                    append_segment(out, char, modes.strings)
                    if escaped then
                        escaped = false
                    elseif char == "\\" then
                        escaped = true
                    elseif char == '"' then
                        in_string = false
                    end
                    index = index + 1
                elseif char == '"' then
                    in_string = true
                    append_segment(out, char, modes.strings)
                    index = index + 1
                elseif
                    char == "/"
                    and next_char == "/"
                    and M.is_line_comment_start(line, index)
                then
                    append_segment(out, line:sub(index), modes.line_comments)
                    break
                elseif char == "/" and next_char == "*" then
                    block_depth = block_depth + 1
                    append_segment(
                        out,
                        line:sub(index, index + 1),
                        modes.block_comments
                    )
                    index = index + 2
                elseif char == "`" then
                    local tick_count = M.backtick_run(line, index)
                    if not tick_count then
                        out[#out + 1] = char
                        index = index + 1
                    else
                        local marker = ("`"):rep(tick_count)
                        local close_start =
                            line:find(marker, index + tick_count, true)
                        if not close_start then
                            break
                        end
                        local close_end = close_start
                                and (close_start + tick_count - 1)
                            or #line
                        append_segment(
                            out,
                            line:sub(index, close_end),
                            modes.raw
                        )
                        index = close_end + 1
                    end
                else
                    out[#out + 1] = char
                    index = index + 1
                end
            end

            masked[row] = table.concat(out)
        end
    end

    return masked
end

function M.mask_line(line, opts)
    return M.mask_lines({ line or "" }, opts)[1] or ""
end

function M.ranges(line, opts)
    opts = opts or {}
    local include = {
        string = opts.strings ~= false,
        line_comment = opts.line_comments ~= false and opts.comments ~= false,
        block_comment = opts.block_comments ~= false and opts.comments ~= false,
        raw = opts.raw ~= false,
    }
    local ranges = {}
    local index = 1
    local in_string = false
    local escaped = false
    local string_start = nil
    local block_depth = 0
    local block_start = nil

    while index <= #line do
        local char = line:sub(index, index)
        local next_char = line:sub(index + 1, index + 1)

        if block_depth > 0 then
            if char == "/" and next_char == "*" then
                block_depth = block_depth + 1
                index = index + 2
            elseif char == "*" and next_char == "/" then
                block_depth = block_depth - 1
                index = index + 2
                if block_depth == 0 and include.block_comment then
                    ranges[#ranges + 1] = { block_start, index - 1, "comment" }
                    block_start = nil
                end
            else
                index = index + 1
            end
        elseif in_string then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                if include.string then
                    ranges[#ranges + 1] = { string_start, index, "string" }
                end
                in_string = false
                string_start = nil
            end
            index = index + 1
        elseif char == '"' then
            in_string = true
            string_start = index
            index = index + 1
        elseif
            char == "/"
            and next_char == "/"
            and M.is_line_comment_start(line, index)
        then
            if include.line_comment then
                ranges[#ranges + 1] = { index, #line, "comment" }
            end
            break
        elseif char == "/" and next_char == "*" then
            block_depth = 1
            block_start = index
            index = index + 2
        elseif char == "`" then
            local tick_count = M.backtick_run(line, index)
            if not tick_count then
                index = index + 1
            else
                local marker = ("`"):rep(tick_count)
                local close_start = line:find(marker, index + tick_count, true)
                if not close_start then
                    break
                end
                local close_end = close_start and (close_start + tick_count - 1)
                    or #line
                if include.raw then
                    ranges[#ranges + 1] = { index, close_end, "raw" }
                end
                index = close_end + 1
            end
        else
            index = index + 1
        end
    end

    if in_string and string_start and include.string then
        ranges[#ranges + 1] = { string_start, #line, "string" }
    end
    if block_depth > 0 and block_start and include.block_comment then
        ranges[#ranges + 1] = { block_start, #line, "comment" }
    end

    return ranges
end

function M.in_ranges(col, ranges)
    for _, range in ipairs(ranges or {}) do
        if col >= range[1] and col <= range[2] then
            return true
        end
    end
    return false
end

function M.line_comment_start(line)
    for _, range in
        ipairs(M.ranges(line, { strings = true, raw = true, comments = true }))
    do
        if
            range[3] == "comment"
            and line:sub(range[1], range[1] + 1) == "//"
        then
            return range[1]
        end
    end
end

function M.strip_line_comment(line)
    local start_col = M.line_comment_start(line or "")
    return start_col and line:sub(1, start_col - 1) or line
end

function M.context_at(lines, row, col)
    return lexical_context.context_at(lines, row, col, M)
end

return M
