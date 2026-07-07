local ts = require("typst.core.treesitter")
local cursor = require("typst.edit.cursor")

local M = {}

local group_punctuation = {
    ["("] = true,
    [")"] = true,
    [","] = true,
}

local function trim(text)
    return (text or ""):match("^%s*(.-)%s*$")
end

local function cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

function M.node_text(bufnr, node)
    return ts.node_text(bufnr, node)
end

function M.range_text(bufnr, range)
    return ts.range_text(bufnr, range)
end

function M.first_child(node, node_type)
    return ts.first_child(node, node_type)
end

local function exact_child(node, node_type)
    for _, child in ipairs(ts.children(node)) do
        if child:type() == node_type then
            return child
        end
    end
end

function M.parent_code_range_for_call(bufnr, call)
    local parent = call:parent()
    if not parent or parent:type() ~= "embedded_code" then
        return nil
    end

    local text = M.node_text(bufnr, parent) or ""
    if text:sub(1, 1) ~= "#" then
        return nil
    end

    return ts.range(parent)
end

function M.content_body_range(content)
    local range = ts.range(content)
    if range.end_row == range.start_row then
        if range.end_col - range.start_col < 2 then
            return nil
        end

        return {
            start_row = range.start_row,
            start_col = range.start_col + 1,
            end_row = range.end_row,
            end_col = range.end_col - 1,
        }
    end

    return {
        start_row = range.start_row,
        start_col = range.start_col + 1,
        end_row = range.end_row,
        end_col = math.max(0, range.end_col - 1),
    }
end

function M.function_name_node(call)
    for _, child in ipairs(ts.children(call)) do
        local node_type = child:type()
        if node_type == "identifier" or node_type == "field_access" then
            return child
        end
    end
end

function M.content_node(call)
    local arguments = M.first_child(call, "arguments")
    return M.first_child(call, "content")
        or (arguments and M.first_child(arguments, "content_block"))
        or nil
end

function M.group_node(call)
    local arguments = exact_child(call, "arguments")
    return (
        arguments
        and exact_child(arguments, "(")
        and exact_child(arguments, ")")
        and arguments
    ) or nil
end

function M.call_name(bufnr, call)
    local ident = M.function_name_node(call)
    return ident and M.node_text(bufnr, ident) or nil
end

local function is_comment_type(node_type)
    return type(node_type) == "string"
        and node_type:find("comment", 1, true) ~= nil
end

local function node_has_comment(node)
    local found = false
    ts.walk(node, function(child)
        if is_comment_type(child:type()) then
            found = true
        end
    end)
    return found
end

function M.group_arguments(bufnr, group)
    local args = {}
    local trailing_comma = false
    local trailing_comma_node = nil
    local has_comment = false

    for _, child in ipairs(ts.children(group)) do
        local node_type = child:type()
        if node_type == "," then
            trailing_comma = true
            trailing_comma_node = child
        elseif is_comment_type(node_type) then
            has_comment = true
        elseif not group_punctuation[node_type] then
            if node_has_comment(child) then
                has_comment = true
            end

            local text = trim(M.range_text(bufnr, ts.range(child)))
            if text ~= "" then
                args[#args + 1] = {
                    text = text,
                    node = child,
                    type = node_type,
                }
                trailing_comma = false
                trailing_comma_node = nil
            end
        end
    end

    return args, trailing_comma, has_comment, trailing_comma_node
end

function M.group_line_indent(bufnr, group)
    local range = ts.range(group)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    return line:match("^%s*") or ""
end

function M.find_call(bufnr, opts)
    opts = opts or {}
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local call = ts.find_containing(bufnr, "function_call", pos)
    if call then
        return call
    end

    local code = ts.find_containing(bufnr, "embedded_code", pos)
    return code and M.first_child(code, "function_call") or nil
end

function M.find_call_group(bufnr, opts)
    local call = M.find_call(bufnr, opts)
    local group = call and M.group_node(call) or nil
    return call, group
end

function M.span(node)
    return ts.node_size(node)
end

function M.find_named_call(bufnr, name, opts)
    opts = opts or {}
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local root = ts.root(bufnr)
    if not root then
        return nil
    end

    local best = nil
    ts.walk(root, function(node)
        if
            node:type() == "function_call"
            and ts.contains(node, pos[1], pos[2])
            and M.call_name(bufnr, node) == name
            and (not best or M.span(node) < M.span(best))
        then
            best = node
        end
    end)
    return best
end

function M.nested_call_name(bufnr, call)
    local name = M.call_name(bufnr, call)
    if name then
        return name
    end

    local child_call = M.first_child(call, "function_call")
    return child_call and M.nested_call_name(bufnr, child_call) or nil
end

return M
