local M = {}

local function quote_start(value, index)
    local char = value:sub(index, index)
    if char == '"' then
        return char
    end
    if char ~= "'" then
        return nil
    end

    local prefix = value:sub(1, index - 1)
    if prefix:match("^%s*$") or prefix:match("[%[{,:]%s*$") then
        return char
    end
end

function M.strip_comment(value)
    local quote = nil
    local escaped = false

    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        else
            local opening = quote_start(value, index)
            if opening then
                quote = opening
            elseif
                char == "#"
                and (index == 1 or value:sub(index - 1, index - 1):match("%s"))
            then
                return value:sub(1, index - 1)
            end
        end
    end

    return value
end

function M.clean_scalar(value)
    value = vim.trim(M.strip_comment(value or ""))
    if value == "" then
        return nil
    end

    local quote = value:sub(1, 1)
    if (quote == '"' or quote == "'") and value:sub(-1) == quote then
        value = value:sub(2, -2)
        if quote == '"' then
            value = value:gsub('\\"', '"'):gsub("\\\\", "\\")
        else
            value = value:gsub("''", "'")
        end
    end

    value = vim.trim(value):gsub("%s+", " ")
    return value ~= "" and value or nil
end

local function inline_container(value, open, close)
    value = vim.trim(M.strip_comment(value or ""))
    if value:sub(1, 1) ~= open or value:sub(-1) ~= close then
        return nil
    end

    local stack = {}
    local quote = nil
    local escaped = false

    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        else
            local opening = quote_start(value, index)
            if opening then
                quote = opening
            elseif char == "[" or char == "{" then
                stack[#stack + 1] = char
            elseif char == "]" or char == "}" then
                local expected = char == "]" and "[" or "{"
                if stack[#stack] ~= expected then
                    return nil
                end
                stack[#stack] = nil
                if #stack == 0 and index ~= #value then
                    return nil
                end
            end
        end
    end

    return #stack == 0 and value:sub(2, -2) or nil
end

local function split_inline_items(value)
    local items = {}
    local start = 1
    local square_depth = 0
    local brace_depth = 0
    local quote = nil
    local escaped = false

    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        else
            local opening = quote_start(value, index)
            if opening then
                quote = opening
            elseif char == "[" then
                square_depth = square_depth + 1
            elseif char == "]" then
                square_depth = math.max(0, square_depth - 1)
            elseif char == "{" then
                brace_depth = brace_depth + 1
            elseif char == "}" then
                brace_depth = math.max(0, brace_depth - 1)
            elseif char == "," and square_depth == 0 and brace_depth == 0 then
                items[#items + 1] = value:sub(start, index - 1)
                start = index + 1
            end
        end
    end

    items[#items + 1] = value:sub(start)
    return items
end

local function inline_colon(value)
    local square_depth = 0
    local brace_depth = 0
    local quote = nil
    local escaped = false

    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        else
            local opening = quote_start(value, index)
            if opening then
                quote = opening
            elseif char == "[" then
                square_depth = square_depth + 1
            elseif char == "]" then
                square_depth = math.max(0, square_depth - 1)
            elseif char == "{" then
                brace_depth = brace_depth + 1
            elseif char == "}" then
                brace_depth = math.max(0, brace_depth - 1)
            elseif char == ":" and square_depth == 0 and brace_depth == 0 then
                return index
            end
        end
    end
end

function M.parse_inline_map(value)
    local body = inline_container(value, "{", "}")
    if not body then
        return nil
    end

    local entries = {}
    for _, item in ipairs(split_inline_items(body)) do
        local colon = inline_colon(item)
        if colon then
            local key = M.clean_scalar(item:sub(1, colon - 1))
            local entry_value = item:sub(colon + 1)
            if key and key ~= "" then
                entries[#entries + 1] = {
                    key = key,
                    value = entry_value,
                }
            end
        end
    end

    return #entries > 0 and entries or nil
end

function M.parse_inline_list(value)
    local body = inline_container(value, "[", "]")
    if not body then
        return nil
    end

    return split_inline_items(body)
end

return M
