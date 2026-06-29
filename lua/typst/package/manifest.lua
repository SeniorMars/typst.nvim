local M = {}

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function starts_with(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function parse_array(value)
    local items = {}
    for item in value:gmatch('"([^"]*)"') do
        items[#items + 1] = item:gsub('\\"', '"'):gsub("\\\\", "\\")
    end
    for item in value:gmatch("'([^']*)'") do
        items[#items + 1] = item
    end
    return items
end

local function parse_value(value)
    value = trim(value)
    if not value then
        return nil
    end

    if starts_with(value, "[") then
        return parse_array(value)
    end

    if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        return value:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
    end

    if value:sub(1, 1) == "'" and value:sub(-1) == "'" then
        return value:sub(2, -2)
    end

    return value
end

local function strip_comment(line)
    local in_single = false
    local in_double = false
    local escaped = false

    for index = 1, #line do
        local char = line:sub(index, index)
        if escaped then
            escaped = false
        elseif char == "\\" and in_double then
            escaped = true
        elseif char == "'" and not in_double then
            in_single = not in_single
        elseif char == '"' and not in_single then
            in_double = not in_double
        elseif char == "#" and not in_single and not in_double then
            return line:sub(1, index - 1)
        end
    end

    return line
end

function M.read(path)
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    local lines = vim.fn.readfile(path)
    local manifest = {}
    local section = nil
    for _, line in ipairs(lines) do
        line = vim.trim(strip_comment(line))
        if line ~= "" then
            local next_section = line:match("^%[([^%]]+)%]$")
            if next_section then
                section = next_section
            elseif section == "package" then
                local key, value = line:match("^([%w_%-]+)%s*=%s*(.+)$")
                if key and value then
                    manifest[key:gsub("-", "_")] = parse_value(value)
                end
            elseif section == "template" then
                local key, value = line:match("^([%w_%-]+)%s*=%s*(.+)$")
                if key and value then
                    manifest.template = manifest.template or {}
                    manifest.template[key:gsub("-", "_")] = parse_value(value)
                end
            elseif section == "tool.typst-docs" then
                local key, value = line:match("^([%w_%-]+)%s*=%s*(.+)$")
                if key and value then
                    manifest.typst_docs = manifest.typst_docs or {}
                    manifest.typst_docs[key:gsub("-", "_")] = parse_value(value)
                end
            end
        end
    end

    return manifest
end

return M
