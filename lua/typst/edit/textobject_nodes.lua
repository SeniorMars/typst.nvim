local content = require("typst.edit.textobject_content")
local delimiters = require("typst.edit.textobject_delimiters")
local ts = require("typst.core.treesitter")
local util = require("typst.edit.textobject_util")

local M = {}

local kinds = {
    heading = { "heading" },
    section = { "heading" },
    equation = { "equation" },
    delimiter = {},
    content = { "content_block", "content" },
    block = {
        "code_block",
        "content_block",
        "raw",
        "content",
        "math",
    },
    structural_block = {
        "code_block",
        "content_block",
        "raw",
        "equation",
        "function_call",
        "arguments",
        "parenthesized_expression",
        "array",
        "dictionary",
        "bullet_list_item",
        "numbered_list_item",
        "term_list_item",
        "content",
        "math",
    },
    code_block = { "raw", "code_block" },
    raw_block = { "raw" },
    call = { "function_call" },
    argument = { "arguments" },
    list_item = {
        "bullet_list_item",
        "numbered_list_item",
        "term_list_item",
    },
    label = { "label", "reference" },
    import = { "module_import" },
}

function M.kinds()
    return kinds
end

function M.node_types(kind)
    return kinds[kind]
end

function M.code_parent_range(node)
    local parent = node and node:parent() or nil
    if parent and parent:type() == "embedded_code" then
        return ts.range(parent)
    end
end

local function import_statement_node(bufnr, opts)
    local pos = opts and opts.pos or nil
    local row, col = util.cursor_position(pos, bufnr)

    local best = nil
    local best_range = nil
    for _, node in ipairs(ts.collect(bufnr, "module_import")) do
        if ts.child_count(node) > 0 then
            local range = M.code_parent_range(node) or ts.range(node)
            if
                util.contains_range(range, row, col)
                and (
                    not best_range
                    or util.range_size(range) < util.range_size(best_range)
                )
            then
                best = node
                best_range = range
            end
        end
    end

    return best
end

local function block_candidate(bufnr, node)
    local node_type = node:type()
    if node_type == "content_block" or node_type == "content" then
        return content.is_bracketed(bufnr, node)
    end

    return true
end

local function find_block_node(bufnr, kind, pos)
    local row, col = util.cursor_position(pos, bufnr)
    local best = nil
    for _, node in ipairs(ts.collect(bufnr, kinds[kind])) do
        local range = ts.range(node)
        if
            block_candidate(bufnr, node)
            and util.contains_range(range, row, col)
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

function M.find(bufnr, kind, opts)
    if kind == "delimiter" then
        return delimiters.find_pair(bufnr, opts.pos)
    end
    if kind == "block" or kind == "structural_block" then
        return find_block_node(bufnr, kind, opts.pos)
    end
    if kind == "content" then
        return content.find_bracketed(bufnr, opts.pos)
    end
    if kind == "import" then
        return import_statement_node(bufnr, opts)
    end

    return ts.find_containing(bufnr, kinds[kind], opts.pos)
end

return M
