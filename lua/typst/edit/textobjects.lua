local arguments = require("typst.edit.textobject_arguments")
local content = require("typst.edit.textobject_content")
local delimiters = require("typst.edit.textobject_delimiters")
local lsp = require("typst.edit.textobject_lsp")
local nodes = require("typst.edit.textobject_nodes")
local ts = require("typst.edit.treesitter")

local M = {}

-- Textobjects prefer local Tree-sitter ranges because they are synchronous and
-- Typst-specific. Tinymist selectionRange is only a fallback for structures the
-- parser/query layer cannot identify.

local function range_for_heading(bufnr, node, part)
    if part == "outer" then
        return ts.range(node)
    end

    local range = ts.range(node)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    local heading_text = line:sub(range.start_col + 1, range.end_col)
    local marker = heading_text:match("^(=+%s*)") or ""

    return ts.trim_whitespace(bufnr, {
        start_row = range.start_row,
        start_col = range.start_col + #marker,
        end_row = range.end_row,
        end_col = range.end_col,
    })
end

local function range_for_section(bufnr, node, part)
    local current = ts.range(node)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        current.start_row,
        current.start_row + 1,
        false
    )[1] or ""
    local level = #(line:match("^%s*(=+)") or "=")

    local section = {
        start_row = current.start_row,
        start_col = current.start_col,
        end_row = vim.api.nvim_buf_line_count(bufnr) - 1,
        end_col = #(vim.api.nvim_buf_get_lines(
            bufnr,
            vim.api.nvim_buf_line_count(bufnr) - 1,
            -1,
            false
        )[1] or ""),
    }

    for _, candidate in ipairs(ts.collect(bufnr, "heading")) do
        local candidate_range = ts.range(candidate)
        if candidate_range.start_row > current.start_row then
            local candidate_line = vim.api.nvim_buf_get_lines(
                bufnr,
                candidate_range.start_row,
                candidate_range.start_row + 1,
                false
            )[1] or ""
            local candidate_level = #(candidate_line:match("^%s*(=+)") or "=")
            if candidate_level <= level then
                section.end_row = candidate_range.start_row
                section.end_col = candidate_range.start_col
                break
            end
        end
    end

    if part == "outer" then
        return ts.trim_whitespace(bufnr, section)
    end

    section.start_row = current.end_row
    section.start_col = current.end_col
    return ts.trim_whitespace(bufnr, section)
end

local function range_for_equation(bufnr, node, part)
    if part == "outer" then
        return ts.range(node)
    end

    if node:type() == "math" then
        return ts.trim_whitespace(bufnr, ts.range(node))
    end

    local math = ts.find_child(node, "math")
    return math and range_for_equation(bufnr, math, part) or nil
end

local function range_after_marker(bufnr, node)
    local range = ts.range(node)
    local marker = ts.children(node)[1]
    if not marker then
        return nil
    end

    local marker_range = ts.range(marker)
    local marker_end_row = marker_range.end_row
    local marker_end_col = marker_range.end_col
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        marker_end_row,
        marker_end_row + 1,
        false
    )[1] or ""
    local start_col = marker_end_col
    while
        start_col < #line and line:sub(start_col + 1, start_col + 1):match("%s")
    do
        start_col = start_col + 1
    end

    return ts.trim_whitespace(bufnr, {
        start_row = marker_end_row,
        start_col = start_col,
        end_row = range.end_row,
        end_col = range.end_col,
    })
end

local function range_for_list_item(bufnr, node, part)
    if part == "outer" then
        return ts.trim_whitespace(bufnr, ts.range(node))
    end

    return range_after_marker(bufnr, node)
end

local function range_for_call(bufnr, node, part)
    if part == "outer" then
        return ts.range(node)
    end

    local arguments = ts.find_child(node, "arguments")

    local parenthesized = arguments
        and ts.find_child(arguments, "(")
        and ts.find_child(arguments, ")")
        and arguments
    if parenthesized then
        return content.delimited_inner(bufnr, parenthesized, 1, 1)
    end

    local content_node = (
        arguments and ts.find_child(arguments, "content_block")
    ) or ts.find_child(node, "content")
    return content_node and content.range(bufnr, content_node, "inner") or nil
end

local function range_for_block(bufnr, node, part)
    local node_type = node:type()
    if node_type == "content_block" or node_type == "content" then
        return content.range(bufnr, node, part)
    end
    if ts.is_type(node, "raw") then
        return content.code_block_range(bufnr, node, part)
    end
    if ts.is_type(node, { "equation", "math" }) then
        return range_for_equation(bufnr, node, part)
    end
    if ts.is_type(node, "function_call") then
        return range_for_call(bufnr, node, part)
    end
    if
        ts.is_type(node, {
            "bullet_list_item",
            "numbered_list_item",
            "term_list_item",
        })
    then
        return range_for_list_item(bufnr, node, part)
    end
    if
        node_type == "code_block"
        or node_type == "parenthesized_expression"
        or node_type == "array"
        or node_type == "dictionary"
    then
        if part == "outer" then
            return ts.range(node)
        end
        return content.delimited_inner(bufnr, node, 1, 1)
    end

    return part == "outer" and ts.range(node)
        or ts.trim_whitespace(bufnr, ts.range(node))
end

local function range_for_label_reference(bufnr, node, part)
    local range = ts.range(node)
    if part == "outer" then
        return range
    end

    local text = ts.node_text(bufnr, node) or ""
    if
        node:type() == "label"
        and text:sub(1, 1) == "<"
        and text:sub(-1) == ">"
    then
        return content.delimited_inner(bufnr, node, 1, 1)
    end
    if node:type() == "reference" and text:sub(1, 1) == "@" then
        return ts.trim_whitespace(bufnr, {
            start_row = range.start_row,
            start_col = range.start_col + 1,
            end_row = range.end_row,
            end_col = range.end_col,
        })
    end

    return ts.trim_whitespace(bufnr, range)
end

local function range_for_import(bufnr, node, part)
    if part == "outer" then
        return nodes.code_parent_range(node) or ts.range(node)
    end

    local keyword = ts.children(node)[1]
    if not keyword then
        return ts.trim_whitespace(bufnr, ts.range(node))
    end

    local keyword_range = ts.range(keyword)
    local start_row = keyword_range.end_row
    local start_col = keyword_range.end_col
    local range = ts.range(node)
    return ts.trim_whitespace(bufnr, {
        start_row = start_row,
        start_col = start_col,
        end_row = range.end_row,
        end_col = range.end_col,
    })
end

local ranges = {
    heading = range_for_heading,
    section = range_for_section,
    equation = range_for_equation,
    delimiter = delimiters.range,
    content = content.range,
    block = range_for_block,
    structural_block = range_for_block,
    code_block = content.code_block_range,
    raw_block = content.code_block_range,
    call = range_for_call,
    argument = arguments.range,
    list_item = range_for_list_item,
    label = range_for_label_reference,
    import = range_for_import,
}

function M.range(kind, part, opts)
    opts = opts or {}
    part = part or "outer"

    if part ~= "inner" and part ~= "outer" then
        error(("typst.nvim: unknown text object part %q"):format(part))
    end

    local node_types = nodes.node_types(kind)
    if not node_types then
        error(("typst.nvim: unknown text object kind %q"):format(kind))
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local node = nodes.find(bufnr, kind, opts)
    if not node then
        if opts.lsp_fallback ~= false then
            if type(opts.callback) == "function" then
                return lsp.selection_range(
                    bufnr,
                    part,
                    vim.tbl_extend("force", opts, {
                        callback = function(result)
                            opts.callback(
                                result and result.range or nil,
                                result
                            )
                        end,
                    })
                )
            end
            return lsp.selection_range(bufnr, part, opts)
        end
        return nil
    end

    local range = ranges[kind](bufnr, node, part, opts)
    if not range and opts.lsp_fallback ~= false then
        if type(opts.callback) == "function" then
            return lsp.selection_range(
                bufnr,
                part,
                vim.tbl_extend("force", opts, {
                    callback = function(result)
                        opts.callback(result and result.range or nil, result)
                    end,
                })
            )
        end
        return lsp.selection_range(bufnr, part, opts)
    end
    return range
end

function M.select(kind, part, opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local callback = opts.callback
    local function finish(range, result)
        if range then
            ts.select_range(bufnr, range)
            if type(callback) == "function" then
                callback(true, result)
            end
            return
        end

        if opts.notify ~= false then
            vim.notify(
                ("No Typst %s %s text object found"):format(
                    part or "outer",
                    kind
                ),
                vim.log.levels.WARN,
                { title = "typst.nvim" }
            )
        end
        if type(callback) == "function" then
            callback(false, result)
        end
    end

    local range = M.range(
        kind,
        part,
        vim.tbl_extend("force", opts, {
            callback = function(resolved, result)
                -- A stale Tinymist response would select text for an older
                -- buffer/cursor state, which is worse than no textobject.
                if result and result.stale then
                    finish(nil, result)
                    return
                end
                finish(resolved, result)
            end,
        })
    )
    if type(range) == "table" and range.pending then
        return range
    end
    if
        type(range) == "table"
        and range.provider == "tinymist"
        and range.ok == false
        and range.start_row == nil
    then
        return range
    end

    if not range then
        finish(nil, { ok = false, reason = "no_range" })
        return false
    end

    ts.select_range(bufnr, range)
    return true
end

return M
