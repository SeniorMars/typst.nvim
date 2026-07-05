local inline = require("typst.bibliography.hayagriva_inline")

local M = {}

M.strip_comment = inline.strip_comment
M.clean_scalar = inline.clean_scalar
M.parse_inline_map = inline.parse_inline_map
M.parse_inline_list = inline.parse_inline_list

function M.indent(line)
    if line:match("^%s*$") or line:match("^%s*#") then
        return nil
    end

    return #(line:match("^(%s*)") or "")
end

local function fold_block(lines)
    local parts = {}
    local current = {}

    local function flush()
        if #current > 0 then
            parts[#parts + 1] = table.concat(current, " ")
            current = {}
        end
    end

    for _, line in ipairs(lines) do
        if line == "" then
            flush()
        else
            current[#current + 1] = vim.trim(line)
        end
    end
    flush()
    return table.concat(parts, "\n")
end

function M.block_value(lines, index, parent_indent, folded)
    local block = {}
    local block_indent = nil
    local row = index + 1

    while row <= #lines do
        local line = lines[row]
        if line:match("^%s*$") then
            if block_indent then
                block[#block + 1] = ""
            end
            row = row + 1
        else
            local indent = M.indent(line)
            if not indent or indent <= parent_indent then
                break
            end

            block_indent = block_indent or indent
            block[#block + 1] = line:sub(block_indent + 1)
            row = row + 1
        end
    end

    local value = folded and fold_block(block) or table.concat(block, "\n")
    value = vim.trim(value):gsub("%s+$", "")
    return value ~= "" and value or nil, row
end

function M.path(stack, key)
    local path = {}
    for _, item in ipairs(stack) do
        path[#path + 1] = item.key
    end
    if key then
        path[#path + 1] = key
    end
    return path
end

function M.field_keys(path)
    return vim.tbl_map(function(key)
        return key:lower()
    end, path or {})
end

function M.full_key(path)
    return table.concat(M.field_keys(path), ".")
end

function M.leaf_key(path)
    local keys = M.field_keys(path)
    return keys[#keys]
end

function M.path_with(path, key)
    local next_path = vim.deepcopy(path or {})
    next_path[#next_path + 1] = key
    return next_path
end

function M.pair(value)
    return (value or ""):match("^([%w_%-]+):%s*(.-)%s*$")
end

function M.person_display(fields)
    local literal = fields.name
        or fields.literal
        or fields.organization
        or fields.organisation
    if literal and literal ~= "" then
        return literal
    end

    local parts = {}
    for _, key in ipairs({
        "prefix",
        "given-name",
        "given",
        "first",
        "family-name",
        "family",
        "last",
        "suffix",
    }) do
        local value = fields[key]
        if value and value ~= "" then
            parts[#parts + 1] = value
        end
    end

    return #parts > 0 and table.concat(parts, " ") or nil
end

return M
