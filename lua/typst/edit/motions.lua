local ts = require("typst.edit.treesitter")
local edit_context = require("typst.edit.context")

local M = {}

local kinds = {
    heading = { "heading" },
    block = {
        "code_block",
        "content_block",
        "arguments",
        "parenthesized_expression",
        "equation",
        "raw",
        "function_call",
        "bullet_list_item",
        "numbered_list_item",
        "term_list_item",
        "content",
        "math",
    },
    equation = { "equation" },
    raw_block = { "raw" },
    comment = { "line_comment", "block_comment" },
}

local labels = {
    raw_block = "raw block",
}

local filters = {}

local function start_pos(node)
    local range = ts.range(node)
    return range.start_row, range.start_col
end

local function end_pos(bufnr, node)
    local row, col = ts.inclusive_end(bufnr, ts.range(node))
    if row then
        return row, col
    end

    return start_pos(node)
end

local function node_pos(bufnr, node, endpoint)
    if endpoint == "end" then
        return end_pos(bufnr, node)
    end

    return start_pos(node)
end

local function before(row_a, col_a, row_b, col_b)
    return row_a < row_b or (row_a == row_b and col_a < col_b)
end

local function is_after(node_row, node_col, row, col)
    return row < node_row or (row == node_row and col < node_col)
end

local function is_before(node_row, node_col, row, col)
    return before(node_row, node_col, row, col)
end

local function wrapped_index(index, count)
    return ((index - 1) % count) + 1
end

filters.block = function(bufnr, node)
    local node_type = node:type()
    if node_type ~= "content_block" and node_type ~= "content" then
        return true
    end

    local text = ts.node_text(bufnr, node) or ""
    return text:sub(1, 1) == "[" and text:sub(-1) == "]"
end

local function collect_nodes(bufnr, kind, node_types, endpoint)
    local nodes = ts.collect(bufnr, node_types)
    local filter = filters[kind]
    if filter then
        nodes = vim.tbl_filter(function(node)
            return filter(bufnr, node)
        end, nodes)
    end

    table.sort(nodes, function(left, right)
        local left_row, left_col = node_pos(bufnr, left, endpoint)
        local right_row, right_col = node_pos(bufnr, right, endpoint)
        return before(left_row, left_col, right_row, right_col)
    end)
    return nodes
end

local function target_index(bufnr, nodes, direction, count, endpoint, row, col)
    local wrap = vim.o.wrapscan

    if direction == "next" then
        local base = nil
        for index, node in ipairs(nodes) do
            local node_row, node_col = node_pos(bufnr, node, endpoint)
            if is_after(node_row, node_col, row, col) then
                base = index
                break
            end
        end

        if not base then
            base = wrap and 1 or nil
        end
        if not base then
            return nil
        end

        local target = base + count - 1
        if target > #nodes and not wrap then
            return nil
        end
        return wrapped_index(target, #nodes)
    end

    local base = nil
    for index = #nodes, 1, -1 do
        local node_row, node_col = node_pos(bufnr, nodes[index], endpoint)
        if is_before(node_row, node_col, row, col) then
            base = index
            break
        end
    end

    if not base then
        base = wrap and #nodes or nil
    end
    if not base then
        return nil
    end

    local target = base - count + 1
    if target < 1 and not wrap then
        return nil
    end
    return wrapped_index(target, #nodes)
end

local function kind_label(kind)
    return labels[kind] or kind
end

local function endpoint_opts(opts, endpoint)
    return vim.tbl_extend("force", opts or {}, { endpoint = endpoint })
end

function M.jump(kind, direction, opts)
    opts = opts or {}
    local endpoint = opts.endpoint or "start"
    if endpoint ~= "start" and endpoint ~= "end" then
        error(("typst.nvim: unknown motion endpoint %q"):format(endpoint))
    end

    local node_types = kinds[kind]
    if not node_types then
        error(("typst.nvim: unknown motion kind %q"):format(kind))
    end

    local ctx = edit_context.resolve(opts, { require_position = true })
    if not ctx then
        return false
    end

    local bufnr = ctx.bufnr
    local nodes = collect_nodes(bufnr, kind, node_types, endpoint)
    if #nodes == 0 then
        vim.notify(
            ("No Typst %s found"):format(kind_label(kind)),
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
        return false
    end

    local index = target_index(
        bufnr,
        nodes,
        direction,
        opts.count or 1,
        endpoint,
        ctx.row,
        ctx.col
    )
    if not index then
        vim.notify(
            ("No %s Typst %s"):format(
                direction == "next" and "next" or "previous",
                kind_label(kind)
            ),
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
        return false
    end

    local row, col = node_pos(bufnr, nodes[index], endpoint)
    if
        ctx.winid == vim.api.nvim_get_current_win()
        and vim.fn.mode(1) == "n"
    then
        pcall(vim.cmd, "normal! m'")
    end
    return edit_context.set_cursor(ctx, row, col)
end

function M.next_heading(opts)
    return M.jump("heading", "next", opts)
end

function M.previous_heading(opts)
    return M.jump("heading", "previous", opts)
end

function M.next_heading_end(opts)
    return M.jump("heading", "next", endpoint_opts(opts, "end"))
end

function M.previous_heading_end(opts)
    return M.jump("heading", "previous", endpoint_opts(opts, "end"))
end

function M.next_block(opts)
    return M.jump("block", "next", opts)
end

function M.previous_block(opts)
    return M.jump("block", "previous", opts)
end

function M.next_block_end(opts)
    return M.jump("block", "next", endpoint_opts(opts, "end"))
end

function M.previous_block_end(opts)
    return M.jump("block", "previous", endpoint_opts(opts, "end"))
end

function M.next_equation(opts)
    return M.jump("equation", "next", opts)
end

function M.previous_equation(opts)
    return M.jump("equation", "previous", opts)
end

function M.next_equation_end(opts)
    return M.jump("equation", "next", endpoint_opts(opts, "end"))
end

function M.previous_equation_end(opts)
    return M.jump("equation", "previous", endpoint_opts(opts, "end"))
end

function M.next_raw_block(opts)
    return M.jump("raw_block", "next", opts)
end

function M.previous_raw_block(opts)
    return M.jump("raw_block", "previous", opts)
end

function M.next_comment(opts)
    return M.jump("comment", "next", opts)
end

function M.previous_comment(opts)
    return M.jump("comment", "previous", opts)
end

return M
