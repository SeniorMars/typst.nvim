local yaml = require("typst.bibliography.hayagriva_yaml")

local M = {}

local function read_lines(path)
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

local clean_yaml_scalar = yaml.clean_scalar
local strip_yaml_comment = yaml.strip_comment
local parse_yaml_inline_map = yaml.parse_inline_map
local parse_yaml_inline_list = yaml.parse_inline_list
local yaml_block_value = yaml.block_value
local yaml_path = yaml.path
local yaml_field_keys = yaml.field_keys
local yaml_full_key = yaml.full_key
local yaml_leaf_key = yaml.leaf_key
local yaml_path_with = yaml.path_with
local yaml_pair = yaml.pair
local yaml_person_display = yaml.person_display

local function record_yaml_list_map(entry, parent_path, item_id, key, value)
    value = clean_yaml_scalar(value)
    if not value or not parent_path or #parent_path == 0 then
        return
    end

    local parent_key = yaml_full_key(parent_path)
    if parent_key == "" then
        return
    end

    entry._yaml_list_maps = entry._yaml_list_maps or {}
    local group = entry._yaml_list_maps[parent_key]
    if not group then
        group = {
            leaf = yaml_leaf_key(parent_path),
            order = {},
            items = {},
        }
        entry._yaml_list_maps[parent_key] = group
    end

    if not group.items[item_id] then
        group.items[item_id] = {}
        group.order[#group.order + 1] = item_id
    end

    group.items[item_id][key:lower()] = value
end

local set_yaml_field_value

local function set_yaml_scalar_field_value(entry, path, value, append)
    value = clean_yaml_scalar(value)
    if not value or #path == 0 then
        return
    end

    local keys = yaml_field_keys(path)
    local full_key = table.concat(keys, ".")
    local leaf_key = keys[#keys]

    if append and entry.fields[full_key] then
        entry.fields[full_key] = entry.fields[full_key] .. "; " .. value
    else
        entry.fields[full_key] = value
    end

    if entry.fields[leaf_key] == nil then
        entry.fields[leaf_key] = entry.fields[full_key]
    elseif append and leaf_key ~= full_key then
        entry.fields[leaf_key] = entry.fields[leaf_key] .. "; " .. value
    end
end

local function set_yaml_inline_map(entry, path, entries, append)
    for _, item in ipairs(entries or {}) do
        set_yaml_field_value(
            entry,
            yaml_path_with(path, item.key),
            item.value,
            append
        )
    end
end

local function set_yaml_inline_list(entry, path, values, append)
    local displays = {}
    local wrote_parent = false

    for _, item in ipairs(values or {}) do
        local map = parse_yaml_inline_map(item)
        if map then
            local fields = {}
            for _, pair in ipairs(map) do
                local scalar = clean_yaml_scalar(pair.value)
                if scalar then
                    fields[pair.key:lower()] = scalar
                end
                set_yaml_field_value(
                    entry,
                    yaml_path_with(path, pair.key),
                    pair.value,
                    true
                )
            end

            local display = yaml_person_display(fields)
            if display then
                displays[#displays + 1] = display
            end
        else
            set_yaml_scalar_field_value(
                entry,
                path,
                item,
                append or wrote_parent
            )
            wrote_parent = true
        end
    end

    if #displays > 0 then
        set_yaml_scalar_field_value(
            entry,
            path,
            table.concat(displays, "; "),
            append or wrote_parent
        )
    end
end

set_yaml_field_value = function(entry, path, value, append)
    value = vim.trim(strip_yaml_comment(value or ""))
    if value == "" or #path == 0 then
        return
    end

    local map = parse_yaml_inline_map(value)
    if map then
        set_yaml_inline_map(entry, path, map, append)
        return
    end

    local list = parse_yaml_inline_list(value)
    if list then
        set_yaml_inline_list(entry, path, list, append)
        return
    end

    set_yaml_scalar_field_value(entry, path, value, append)
end

local function set_yaml_field(entry, path, value)
    set_yaml_field_value(entry, path, value, false)
end

local function append_yaml_field(entry, path, value)
    set_yaml_field_value(entry, path, value, true)
end

local function finalize_yaml_list_maps(entry)
    local maps = entry._yaml_list_maps
    entry._yaml_list_maps = nil
    if not maps then
        return
    end

    for full_key, group in pairs(maps) do
        local values = {}
        for _, item_id in ipairs(group.order or {}) do
            local display = yaml_person_display(group.items[item_id] or {})
            if display then
                values[#values + 1] = display
            end
        end

        if #values > 0 then
            local value = table.concat(values, "; ")
            entry.fields[full_key] = value
            if group.leaf then
                entry.fields[group.leaf] = value
            end
        end
    end
end

function M.parse_hayagriva_lines(lines)
    lines = lines or {}
    local entries = {}
    local current = nil
    local stack = {}
    local current_list_item = nil
    local index = 1

    while index <= #lines do
        local line = lines[index]
        local top_key, top_value = line:match("^([%w_.:/%-]+):%s*(.-)%s*$")
        if top_key then
            current = {
                type = "hayagriva",
                key = top_key,
                lnum = index,
                col = 1,
                fields = {},
            }
            entries[#entries + 1] = current
            stack = {}
            current_list_item = nil
            if clean_yaml_scalar(top_value) then
                current.fields.value = clean_yaml_scalar(top_value)
            end
            index = index + 1
        elseif current then
            local indent_text, key, value =
                line:match("^(%s+)([%w_%-]+):%s*(.-)%s*$")
            if indent_text and key then
                local indent = #indent_text
                if current_list_item and indent <= current_list_item.indent then
                    current_list_item = nil
                end

                if current_list_item and indent > current_list_item.indent then
                    value = vim.trim(strip_yaml_comment(value or ""))
                    if value == "" then
                        index = index + 1
                    elseif value:sub(1, 1) == "|" or value:sub(1, 1) == ">" then
                        local block, next_index = yaml_block_value(
                            lines,
                            index,
                            indent,
                            value:sub(1, 1) == ">"
                        )
                        append_yaml_field(
                            current,
                            yaml_path_with(current_list_item.parent_path, key),
                            block
                        )
                        record_yaml_list_map(
                            current,
                            current_list_item.parent_path,
                            current_list_item.id,
                            key,
                            block
                        )
                        index = next_index
                    else
                        append_yaml_field(
                            current,
                            yaml_path_with(current_list_item.parent_path, key),
                            value
                        )
                        record_yaml_list_map(
                            current,
                            current_list_item.parent_path,
                            current_list_item.id,
                            key,
                            value
                        )
                        index = index + 1
                    end
                else
                    while #stack > 0 and stack[#stack].indent >= indent do
                        stack[#stack] = nil
                    end

                    value = vim.trim(strip_yaml_comment(value or ""))
                    if value == "" then
                        stack[#stack + 1] = { indent = indent, key = key }
                        index = index + 1
                    elseif value:sub(1, 1) == "|" or value:sub(1, 1) == ">" then
                        local block, next_index = yaml_block_value(
                            lines,
                            index,
                            indent,
                            value:sub(1, 1) == ">"
                        )
                        set_yaml_field(current, yaml_path(stack, key), block)
                        index = next_index
                    else
                        set_yaml_field(current, yaml_path(stack, key), value)
                        index = index + 1
                    end
                end
            else
                local item_indent_text, item_value =
                    line:match("^(%s+)%-%s+(.-)%s*$")
                if item_indent_text and item_value and #stack > 0 then
                    local indent = #item_indent_text
                    while #stack > 0 and stack[#stack].indent >= indent do
                        stack[#stack] = nil
                    end

                    if #stack > 0 then
                        item_value =
                            vim.trim(strip_yaml_comment(item_value or ""))
                        local key, value = yaml_pair(item_value)
                        if key and value and value ~= "" then
                            local parent_path = yaml_path(stack)
                            current_list_item = {
                                id = tostring(index),
                                indent = indent,
                                parent_path = parent_path,
                            }
                            append_yaml_field(
                                current,
                                yaml_path_with(parent_path, key),
                                value
                            )
                            record_yaml_list_map(
                                current,
                                parent_path,
                                current_list_item.id,
                                key,
                                value
                            )
                        else
                            current_list_item = nil
                            append_yaml_field(
                                current,
                                yaml_path(stack),
                                item_value
                            )
                        end
                    end
                end

                index = index + 1
            end
        else
            index = index + 1
        end
    end

    for _, entry in ipairs(entries) do
        finalize_yaml_list_maps(entry)
    end

    return entries
end

function M.parse_hayagriva_file(path)
    return M.parse_hayagriva_lines(read_lines(path))
end

function M.hayagriva_entry(path, key, lnum)
    for _, entry in ipairs(M.parse_hayagriva_file(path)) do
        if key and entry.key == key then
            return entry
        end
        if lnum and entry.lnum == lnum then
            return entry
        end
    end
end

function M.hayagriva_fields(path, key, lnum)
    local entry = M.hayagriva_entry(path, key, lnum)
    return entry and entry.fields or {}
end

return M
