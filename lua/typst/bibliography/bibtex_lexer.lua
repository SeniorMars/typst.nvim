local M = {}

function M.read_lines(path)
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

function M.line_offsets(lines)
    local offsets = {}
    local offset = 1
    for lnum, line in ipairs(lines) do
        offsets[lnum] = offset
        offset = offset + #line + 1
    end
    return offsets
end

function M.offset_position(offsets, offset)
    if #offsets == 0 then
        return 1, offset
    end

    local low = 1
    local high = #offsets
    local line = 1

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local start = offsets[mid]
        if start and start <= offset then
            line = mid
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return line, offset - offsets[line] + 1
end

function M.scrub_comments(lines)
    local scrubbed = {}
    local brace_depth = 0
    local quote = false
    local escaped = false

    for lnum, line in ipairs(lines or {}) do
        local chars = {}
        local index = 1

        while index <= #line do
            local char = line:sub(index, index)
            if quote then
                chars[#chars + 1] = char
                if escaped then
                    escaped = false
                elseif char == "\\" then
                    escaped = true
                elseif char == '"' then
                    quote = false
                end
            elseif char == '"' then
                quote = true
                chars[#chars + 1] = char
            elseif char == "{" then
                brace_depth = brace_depth + 1
                chars[#chars + 1] = char
            elseif char == "}" then
                if brace_depth > 0 then
                    brace_depth = brace_depth - 1
                end
                chars[#chars + 1] = char
            elseif char == "%" and brace_depth == 0 then
                chars[#chars + 1] = (" "):rep(#line - index + 1)
                break
            else
                chars[#chars + 1] = char
            end
            index = index + 1
        end

        scrubbed[lnum] = table.concat(chars)
    end

    return scrubbed
end

function M.skip_space(text, index, stop)
    while index <= stop and text:sub(index, index):match("%s") do
        index = index + 1
    end
    return index
end

function M.skip_space_and_comments(text, index, stop)
    while index <= stop do
        index = M.skip_space(text, index, stop)
        if text:sub(index, index) ~= "%" then
            return index
        end

        local newline = text:find("\n", index, true)
        if not newline or newline > stop then
            return stop + 1
        end
        index = newline + 1
    end

    return index
end

function M.matching_close(open)
    return open == "{" and "}" or ")"
end

function M.find_matching(text, index, stop, open, close)
    local depth = 1
    local quote = false
    local escaped = false
    index = index + 1

    while index <= stop do
        local char = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                quote = false
            end
        elseif char == '"' then
            quote = true
        elseif char == open then
            depth = depth + 1
        elseif char == close then
            depth = depth - 1
            if depth == 0 then
                return index
            end
        end
        index = index + 1
    end
end

function M.field_value_end(text, index, stop)
    local brace_depth = 0
    local paren_depth = 0
    local quote = false
    local escaped = false

    while index <= stop do
        local char = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                quote = false
            end
        elseif char == '"' then
            quote = true
        elseif char == "{" then
            brace_depth = brace_depth + 1
        elseif char == "}" then
            if brace_depth > 0 then
                brace_depth = brace_depth - 1
            end
        elseif char == "(" then
            paren_depth = paren_depth + 1
        elseif char == ")" then
            if paren_depth > 0 then
                paren_depth = paren_depth - 1
            end
        elseif char == "," and brace_depth == 0 and paren_depth == 0 then
            return index - 1, index + 1
        end
        index = index + 1
    end

    return stop, stop + 1
end

return M
