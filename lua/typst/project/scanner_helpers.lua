local lexical = require("typst.syntax.lexical")
local tables = require("typst.core.tables")

local M = {}
local unpack = tables.unpack

function M.trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

function M.add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

function M.source_location(path, row, col)
    return {
        path = path,
        lnum = row,
        col = col or 1,
    }
end

local function split_top_level(text)
    local parts = {}
    local start = 1
    local depth = 0
    local quote = nil
    local escaped = false

    for index = 1, #text do
        local char = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        elseif char == '"' then
            quote = char
        elseif char == "(" or char == "[" or char == "{" then
            depth = depth + 1
        elseif char == ")" or char == "]" or char == "}" then
            if depth > 0 then
                depth = depth - 1
            end
        elseif char == "," and depth == 0 then
            parts[#parts + 1] = text:sub(start, index - 1)
            start = index + 1
        end
    end

    parts[#parts + 1] = text:sub(start)
    return parts
end

function M.parse_function_parameters(group_text)
    if
        type(group_text) ~= "string"
        or group_text:sub(1, 1) ~= "("
        or group_text:sub(-1) ~= ")"
    then
        return {}
    end

    local params = {}
    for _, part in ipairs(split_top_level(group_text:sub(2, -2))) do
        part = M.trim(part)
        if part and part:sub(1, 2) ~= ".." then
            local name, default = part:match("^([%a_][%w_%-]*)%s*:%s*(.+)$")
            if not name then
                name = part:match("^([%a_][%w_%-]*)$")
            end

            if name then
                params[#params + 1] = {
                    name = name,
                    named = true,
                    required = default == nil,
                    default = default and M.trim(default) or nil,
                }
            end
        end
    end

    return params
end

local function declaration_group(rest)
    return rest:match("^%s*(%b())")
end

function M.strip_line_comment(line)
    return lexical.strip_line_comment(line)
end

local function parenthesized_prefix(text)
    if type(text) ~= "string" or text:sub(1, 1) ~= "(" then
        return nil
    end

    local depth = 0
    local quote = nil
    local escaped = false

    for index = 1, #text do
        local char = text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        elseif char == '"' then
            quote = char
        elseif char == "(" then
            depth = depth + 1
        elseif char == ")" then
            depth = depth - 1
            if depth == 0 then
                return text:sub(1, index)
            end
        end
    end
end

function M.declaration_group_from_lines(lines, row, code_line, end_col)
    local rest = code_line:sub(end_col + 1)
    local group = declaration_group(rest)
    if group then
        return group
    end

    local start_col = rest:find("%S")
    if not start_col or rest:sub(start_col, start_col) ~= "(" then
        return nil
    end

    local parts = { rest:sub(start_col) }
    local max_row = math.min(#lines, row + 50)
    for next_row = row + 1, max_row do
        parts[#parts + 1] = M.strip_line_comment(lines[next_row] or "")
        group = parenthesized_prefix(table.concat(parts, "\n"))
        if group then
            return group
        end
    end
end

function M.enclosing_call_name(prefix)
    local call = prefix:match("([#%a_][%w_%.%-]*)%s*%(%s*$")
    if not call then
        return nil
    end

    return call:gsub("^#", ""):match("([%w_%-]+)$")
end

function M.quoted_ranges(line)
    return lexical.ranges(line, {
        strings = true,
        raw = true,
        comments = true,
    })
end

function M.in_ranges(col, ranges)
    return lexical.in_ranges(col, ranges)
end

function M.line_comment_start(line)
    return lexical.line_comment_start(line)
end

function M.scrub_non_code_regions(lines)
    return lexical.mask_lines(lines, {
        strings = "keep",
        line_comments = "keep",
        block_comments = "space",
        raw = "space",
    })
end

function M.strip_strings(line)
    local ranges = M.quoted_ranges(line)
    if #ranges == 0 then
        return line
    end

    local chars = {}
    for index = 1, #line do
        chars[index] = line:sub(index, index)
    end

    for _, range in ipairs(ranges) do
        if range[3] == "string" then
            for index = range[1], range[2] do
                chars[index] = " "
            end
        end
    end

    return table.concat(chars)
end

function M.find_code(line, pattern, init, plain)
    local search_at = init or 1
    local ranges = M.quoted_ranges(line)

    while true do
        local match = { line:find(pattern, search_at, plain) }
        local start_col = match[1]
        local end_col = match[2]
        if not start_col then
            return nil
        end

        if not M.in_ranges(start_col, ranges) then
            return unpack(match)
        end

        search_at = math.max(end_col + 1, start_col + 1)
    end
end

function M.path_scan_helpers()
    return {
        trim = M.trim,
        add_unique = M.add_unique,
        source_location = M.source_location,
        strip_line_comment = M.strip_line_comment,
        find_code = M.find_code,
    }
end

return M
