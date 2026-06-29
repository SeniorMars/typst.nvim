local M = {}

function M.context_at(lines, row, col, lexical)
    local block_depth = 0
    local fence = nil

    for line_index, line in ipairs(lines or {}) do
        local target_line = line_index == row + 1
        local _, fence_ticks = lexical.raw_fence_marker(line)

        if fence then
            if target_line then
                return "raw"
            end
            if fence_ticks and #fence_ticks >= #fence then
                fence = nil
            end
        elseif fence_ticks then
            if target_line then
                return "raw"
            end
            fence = fence_ticks
        else
            local index = 1
            local in_string = false
            local escaped = false

            while index <= #line do
                local char = line:sub(index, index)
                local next_char = line:sub(index + 1, index + 1)
                local byte_col = index - 1

                if block_depth > 0 then
                    if target_line and col == byte_col then
                        return "comment"
                    end

                    if char == "/" and next_char == "*" then
                        block_depth = block_depth + 1
                        index = index + 2
                    elseif char == "*" and next_char == "/" then
                        block_depth = block_depth - 1
                        index = index + 2
                    else
                        index = index + 1
                    end
                elseif in_string then
                    if target_line and col == byte_col then
                        return "string"
                    end

                    if escaped then
                        escaped = false
                    elseif char == "\\" then
                        escaped = true
                    elseif char == '"' then
                        in_string = false
                    end
                    index = index + 1
                elseif char == '"' then
                    if target_line and col == byte_col then
                        return "string"
                    end
                    in_string = true
                    index = index + 1
                elseif
                    char == "/"
                    and next_char == "/"
                    and lexical.is_line_comment_start(line, index)
                then
                    if target_line and col >= byte_col then
                        return "comment"
                    end
                    break
                elseif char == "/" and next_char == "*" then
                    if
                        target_line
                        and col >= byte_col
                        and col < byte_col + 2
                    then
                        return "comment"
                    end
                    block_depth = block_depth + 1
                    index = index + 2
                elseif char == "`" then
                    local tick_count = lexical.backtick_run(line, index)
                    local marker = ("`"):rep(tick_count)
                    local close_start =
                        line:find(marker, index + tick_count, true)
                    local close_end = close_start
                            and (close_start + tick_count - 1)
                        or #line
                    if target_line and col >= byte_col and col < close_end then
                        return "raw"
                    end
                    index = close_end + 1
                else
                    index = index + 1
                end
            end

            if target_line then
                if block_depth > 0 and col >= #line then
                    return "comment"
                end
                if in_string and col >= #line then
                    return "string"
                end
                return "code"
            end
        end
    end

    return "code"
end

return M
