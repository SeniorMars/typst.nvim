local ts = require("typst.core.treesitter")
local util = require("typst.edit.textobject_util")

local M = {}

local function child_range(node, node_type)
    local child = ts.find_child(node, node_type)
    return child and ts.range(child) or nil
end

function M.delimited_inner(bufnr, node, prefix_len, suffix_len)
    local range = ts.range(node)
    local inner = {
        start_row = range.start_row,
        start_col = range.start_col + prefix_len,
        end_row = range.end_row,
        end_col = range.end_col - suffix_len,
    }

    return ts.trim_whitespace(bufnr, inner)
end

function M.is_bracketed(bufnr, node)
    local node_type = node:type()
    if node_type ~= "content_block" and node_type ~= "content" then
        return false
    end

    local text = ts.node_text(bufnr, node) or ""
    return text:sub(1, 1) == "[" and text:sub(-1) == "]"
end

function M.find_bracketed(bufnr, pos)
    local row, col = util.cursor_position(pos, bufnr)
    if not row or not col then
        return nil
    end

    local best = nil
    for _, node in ipairs(ts.collect(bufnr, { "content_block", "content" })) do
        local range = ts.range(node)
        if
            M.is_bracketed(bufnr, node) and util.contains_range(range, row, col)
        then
            if
                not best
                or util.range_size(range) < util.range_size(ts.range(best))
            then
                best = node
            end
        end
    end

    return best
end

function M.range(bufnr, node, part)
    if part == "outer" then
        return ts.range(node)
    end

    return M.delimited_inner(bufnr, node, 1, 1)
end

function M.code_block_range(bufnr, node, part)
    if part == "outer" then
        return ts.range(node)
    end

    if node:type() == "raw" then
        local content = child_range(node, "raw_content")
        return content and ts.trim_whitespace(bufnr, content) or nil
    end

    return M.delimited_inner(bufnr, node, 1, 1)
end

return M
