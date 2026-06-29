local core_util = require("typst.core.util")
local ts = require("typst.core.treesitter")

local M = {}

function M.range_from_node(node)
    return ts.range(node)
end

function M.range_contains(range, row, col)
    return ts.contains_range(range, row, col)
end

function M.range_before(left, right)
    return ts.range_before(left, right)
end

function M.overlaps(left, right)
    return ts.overlaps(left, right)
end

function M.line_range(start_row, end_row)
    return ts.line_range(start_row, end_row)
end

function M.range_size(range)
    return ts.range_size(range)
end

function M.range_text(bufnr, range)
    return ts.range_text(bufnr, range)
end

function M.first_child(node, node_type)
    return ts.first_child(node, node_type)
end

function M.children(node)
    return ts.children(node)
end

function M.child_count(node)
    return ts.child_count(node)
end

function M.node_text(bufnr, node)
    return ts.node_text(bufnr, node)
end

function M.expression_source_range(node)
    local parent = node:parent()
    if parent and parent:type() == "embedded_code" then
        return M.range_from_node(parent)
    end
    return M.range_from_node(node)
end

function M.normalize_symbol_name(source)
    source = (source or ""):gsub("^#", "")
    local explicit = source:sub(1, 4) == "sym."
    if explicit then
        return source:sub(5), true
    end
    return source, false
end

function M.normalize_emoji_name(source)
    source = (source or ""):gsub("^#", "")
    if source:sub(1, 6) == "emoji." then
        return source:sub(7)
    end
end

function M.replacement_safe(replacement, opts)
    if type(replacement) ~= "string" then
        return false
    end
    if replacement == "" then
        return true
    end

    local safety = opts.safety or {}
    local max_width = safety.max_display_width or 1
    if vim.fn.strdisplaywidth(replacement) > max_width then
        return false
    end
    if
        not safety.allow_combining
        and vim.fn.strdisplaywidth(replacement) == 0
    then
        return false
    end
    return core_util.scalar_count(replacement) == 1
end

function M.display_safe(record, opts)
    if record.nvim_conceal_safe == false then
        return false
    end
    return M.replacement_safe(record.glyph, opts)
end

function M.collect_error_ranges(node, ranges, limit)
    return ts.collect_error_ranges(node, ranges, limit)
end

function M.intersects_error_range(range, error_ranges)
    return ts.intersects_error_range(range, error_ranges)
end

return M
