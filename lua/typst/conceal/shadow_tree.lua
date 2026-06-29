local M = {}
local ts = require("typst.core.treesitter")

function M.range_from_node(node)
    return ts.range(node)
end

function M.range_contains(range, row, col)
    return ts.contains_range(range, row, col)
end

function M.node_id(node)
    return ts.node_id(node)
end

function M.syntax_signature(bufnr, root)
    return ts.syntax_signature(bufnr, root)
end

function M.children(node)
    return ts.children(node)
end

function M.node_text(bufnr, node)
    return ts.node_text(bufnr, node)
end

function M.first_ident_text(bufnr, node)
    for _, child in ipairs(ts.children(node)) do
        if child:type() == "identifier" then
            return ts.node_text(bufnr, child)
        end
    end
end

function M.last_ident_text(bufnr, node)
    local last = nil

    local function walk(current)
        if current:type() == "identifier" then
            last = ts.node_text(bufnr, current)
        end
        for _, child in ipairs(ts.children(current)) do
            walk(child)
        end
    end

    walk(node)
    return last
end

function M.first_child(node, node_type)
    return ts.first_child(node, node_type)
end

function M.import_binding_name(bufnr, node)
    local text = ts.node_text(bufnr, node) or ""
    local alias = text:match("%s+as%s+([%a_][%w_%-]*)%s*$")
    if alias then
        return alias
    end

    return M.last_ident_text(bufnr, node)
end

function M.let_binding_name(bufnr, node)
    for _, child in ipairs(ts.children(node)) do
        if child:type() == "identifier" then
            return ts.node_text(bufnr, child)
        end
    end
end

function M.let_body_scope(node)
    local content = M.first_child(node, "content_block")
    if content then
        return M.range_from_node(content)
    end

    local block = M.first_child(node, "code_block")
    if block then
        return M.range_from_node(block)
    end
end

function M.position_leq(left_row, left_col, right_row, right_col)
    return ts.position_leq(left_row, left_col, right_row, right_col)
end

function M.lexical_scope(node)
    local current = node and node:parent()
    while current do
        local node_type = current:type()
        if
            node_type == "code_block"
            or node_type == "content_block"
            or node_type == "content"
            or node_type == "source_file"
        then
            return M.range_from_node(current)
        end
        current = current:parent()
    end
end

return M
