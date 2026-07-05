local content = require("typst.edit.textobject_content")
local ts = require("typst.edit.treesitter")
local util = require("typst.edit.textobject_util")

local M = {}

local function argument_children(group)
    local children = {}
    for _, child in ipairs(ts.children(group)) do
        local node_type = child:type()
        if node_type ~= "(" and node_type ~= ")" and node_type ~= "," then
            children[#children + 1] = child
        end
    end
    return children
end

local function find_argument(bufnr, group, pos)
    local row, col = util.cursor_position(pos, bufnr)
    if not row or not col then
        return nil
    end

    local best = nil
    for _, child in ipairs(argument_children(group)) do
        local range = ts.range(child)
        if util.contains_range(range, row, col) then
            if
                not best
                or util.range_size(range) < util.range_size(ts.range(best))
            then
                best = child
            end
        end
    end

    return best
end

local function find_argument_index(bufnr, group, pos)
    local argument = find_argument(bufnr, group, pos)
    if not argument then
        return nil, nil, nil
    end

    local children = argument_children(group)
    for index, child in ipairs(children) do
        if child == argument then
            return argument, children, index
        end
    end

    return argument, children, nil
end

local function counted_argument_range(bufnr, group, part, opts)
    local count = math.max(1, opts and opts.count or 1)
    if count == 1 or part ~= "outer" then
        return nil
    end

    local _, children, start_index =
        find_argument_index(bufnr, group, opts and opts.pos or nil)
    if not start_index then
        return false
    end

    local end_index = start_index + count - 1
    if type(children) ~= "table" or end_index > #children then
        return false
    end

    local start_child = children[start_index]
    local end_child = children[end_index]
    if not start_child or not end_child then
        return false
    end

    local start_range = ts.trim_whitespace(bufnr, ts.range(start_child))
    local end_range = ts.trim_whitespace(bufnr, ts.range(end_child))
    if not start_range or not end_range then
        return false
    end

    return ts.trim_whitespace(bufnr, {
        start_row = start_range.start_row,
        start_col = start_range.start_col,
        end_row = end_range.end_row,
        end_col = end_range.end_col,
    })
end

local function tagged_value_range(bufnr, node)
    local value = nil
    for _, child in ipairs(ts.children(node)) do
        local node_type = child:type()
        if node_type ~= "identifier" and node_type ~= ":" then
            value = child
        end
    end

    return value and ts.trim_whitespace(bufnr, ts.range(value)) or nil
end

function M.range(bufnr, node, part, opts)
    local counted = counted_argument_range(bufnr, node, part, opts)
    if counted ~= nil then
        return counted
    end

    local argument = find_argument(bufnr, node, opts and opts.pos or nil)
    if not argument then
        return nil
    end

    if part == "outer" then
        return ts.trim_whitespace(bufnr, ts.range(argument))
    end

    if argument:type() == "named_argument" then
        return tagged_value_range(bufnr, argument)
    end

    if content.is_bracketed(bufnr, argument) then
        return content.range(bufnr, argument, "inner")
    end

    return ts.trim_whitespace(bufnr, ts.range(argument))
end

return M
