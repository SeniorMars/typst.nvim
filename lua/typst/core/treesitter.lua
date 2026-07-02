local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
local windows = require("typst.core.windows")

local M = {}

local collect_cache = {}

local type_aliases = {
    block = { "code_block" },
    branch = { "if_expression" },
    call = { "function_call" },
    comment = { "line_comment", "block_comment" },
    content = { "content_block" },
    emph = { "emphasis" },
    field = { "field_access", "math_field_access" },
    for_loop = { "for_loop" },
    group = { "arguments", "parenthesized_expression" },
    import = { "module_import" },
    lambda = { "closure" },
    let = { "let_binding" },
    module_import = { "module_import" },
    set = { "set_rule" },
    show = { "show_rule" },
}

local function as_type_set(types)
    if type(types) == "string" then
        types = { types }
    end

    local set = {}
    for _, node_type in ipairs(types or {}) do
        set[node_type] = true
        for _, alias in ipairs(type_aliases[node_type] or {}) do
            set[alias] = true
        end
    end
    return set
end

local function type_key(types)
    local set = as_type_set(types)
    local keys = vim.tbl_keys(set)
    table.sort(keys)
    return table.concat(keys, "\0")
end

local function copy_nodes(nodes)
    local copy = {}
    for index, node in ipairs(nodes or {}) do
        copy[index] = node
    end
    return copy
end

local function before(row_a, col_a, row_b, col_b)
    return row_a < row_b or (row_a == row_b and col_a < col_b)
end

local function node_span(node)
    local start_row, start_col, end_row, end_col = node:range()
    return (end_row - start_row) * 100000 + (end_col - start_col)
end

local function cursor_pos(bufnr)
    local winid = windows.for_buffer(bufnr)
    if not winid then
        return nil, nil
    end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return cursor[1] - 1, cursor[2]
end

function M.root(bufnr, lang)
    bufnr = normalize_bufnr(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang or "typst")
    if not ok or not parser then
        return nil
    end

    local parsed_ok, trees = pcall(parser.parse, parser)
    if not parsed_ok or not trees or not trees[1] then
        return nil
    end

    return trees[1]:root()
end

function M.child_count(node)
    if not node then
        return 0
    end
    if type(node.child_count) == "function" then
        local ok, count = pcall(node.child_count, node)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 0
end

function M.named_child_count(node)
    if not node then
        return 0
    end
    if type(node.named_child_count) == "function" then
        local ok, count = pcall(node.named_child_count, node)
        if ok and type(count) == "number" then
            return count
        end
    end
    return M.child_count(node)
end

function M.children(node)
    local out = {}
    if not node then
        return out
    end

    local count = M.child_count(node)
    if count > 0 and type(node.child) == "function" then
        for index = 0, count - 1 do
            local child = node:child(index)
            if child then
                out[#out + 1] = child
            end
        end
        return out
    end

    if type(node.iter_children) == "function" then
        for child in node:iter_children() do
            out[#out + 1] = child
        end
    end
    return out
end

function M.walk(node, callback)
    if not node then
        return
    end

    local stack = { node }
    while #stack > 0 do
        local current = table.remove(stack)
        callback(current)

        local children = M.children(current)
        for index = #children, 1, -1 do
            stack[#stack + 1] = children[index]
        end
    end
end

function M.range(node)
    local start_row, start_col, end_row, end_col = node:range()
    return {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
    }
end

M.range_from_node = M.range

function M.line_range(start_row, end_row)
    return {
        start_row = start_row,
        start_col = 0,
        end_row = end_row,
        end_col = 0,
    }
end

function M.range_before(left, right)
    return left.end_row < right.start_row
        or (left.end_row == right.start_row and left.end_col <= right.start_col)
end

function M.overlaps(left, right)
    return not M.range_before(left, right) and not M.range_before(right, left)
end

function M.range_size(range)
    return (range.end_row - range.start_row) * 100000
        + (range.end_col - range.start_col)
end

function M.node_size(node)
    return node_span(node)
end

function M.is_type(node, types)
    if not node then
        return false
    end
    return as_type_set(types)[node:type()] == true
end

function M.contains_range(range, row, col)
    local after_start = row > range.start_row
        or (row == range.start_row and col >= range.start_col)
    local before_end = row < range.end_row
        or (row == range.end_row and col < range.end_col)
    return after_start and before_end
end

function M.contains(node, row, col)
    return M.contains_range(M.range(node), row, col)
end

function M.node_text(bufnr, node)
    local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
    return ok and text or nil
end

function M.range_text(bufnr, range)
    bufnr = normalize_bufnr(bufnr)
    local lines = vim.api.nvim_buf_get_text(
        bufnr,
        range.start_row,
        range.start_col,
        range.end_row,
        range.end_col,
        {}
    )
    return table.concat(lines, "\n")
end

function M.first_child(node, node_type)
    local wanted = as_type_set(node_type)
    for _, child in ipairs(M.children(node)) do
        if wanted[child:type()] then
            return child
        end
    end
end

M.find_child = M.first_child

function M.collect(bufnr, types)
    bufnr = normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local key = type_key(types)
    local cached = collect_cache[bufnr] and collect_cache[bufnr][key]
    if cached and cached.changedtick == changedtick then
        return copy_nodes(cached.nodes)
    end

    local root = M.root(bufnr)
    if not root then
        collect_cache[bufnr] = collect_cache[bufnr] or {}
        collect_cache[bufnr][key] = {
            changedtick = changedtick,
            nodes = {},
        }
        return {}
    end

    local wanted = as_type_set(types)
    local nodes = {}
    M.walk(root, function(node)
        if wanted[node:type()] then
            nodes[#nodes + 1] = node
        end
    end)

    table.sort(nodes, function(a, b)
        local a_row, a_col = a:range()
        local b_row, b_col = b:range()
        return before(a_row, a_col, b_row, b_col)
    end)

    collect_cache[bufnr] = collect_cache[bufnr] or {}
    collect_cache[bufnr][key] = {
        changedtick = changedtick,
        nodes = nodes,
    }
    return copy_nodes(nodes)
end

function M.forget(bufnr)
    if bufnr then
        collect_cache[normalize_bufnr(bufnr)] = nil
        return true
    end

    collect_cache = {}
    return true
end

M.reset = M.forget

function M.node_at_pos(bufnr, pos)
    bufnr = normalize_bufnr(bufnr)
    local row, col
    if pos then
        row, col = pos[1], pos[2]
    else
        row, col = cursor_pos(bufnr)
    end
    if not row or not col then
        return nil
    end

    local root = M.root(bufnr)
    if not root then
        if type(vim.treesitter.get_node) == "function" then
            local ok, node = pcall(vim.treesitter.get_node, {
                bufnr = bufnr,
                lang = "typst",
                pos = { row, col },
                ignore_injections = true,
            })
            if ok and node then
                return node
            end
        end
        return nil
    end

    for _, method in ipairs({
        "named_descendant_for_range",
        "descendant_for_range",
    }) do
        if type(root[method]) == "function" then
            local ok, node = pcall(root[method], root, row, col, row, col)
            if ok and node then
                return node
            end
        end
    end
end

function M.ancestor_of_type(node, types, pos)
    local wanted = as_type_set(types)
    local row, col
    if pos then
        row, col = pos[1], pos[2]
    end

    while node do
        if
            wanted[node:type()]
            and (not row or not col or M.contains(node, row, col))
        then
            return node
        end
        node = node:parent()
    end
end

function M.parent_of_type(node, types, pos)
    return M.ancestor_of_type(node and node:parent() or nil, types, pos)
end

function M.find_containing(bufnr, types, pos)
    bufnr = normalize_bufnr(bufnr)
    local row, col
    if pos then
        row, col = pos[1], pos[2]
    else
        row, col = cursor_pos(bufnr)
    end
    if not row or not col then
        return nil
    end

    local nearest = M.node_at_pos(bufnr, { row, col })
    local ancestor = M.ancestor_of_type(nearest, types, { row, col })
    if ancestor then
        return ancestor
    end

    local root = M.root(bufnr)
    if not root then
        return nil
    end

    local wanted = as_type_set(types)
    local best = nil
    M.walk(root, function(node)
        if wanted[node:type()] and M.contains(node, row, col) then
            if not best or node_span(node) < node_span(best) then
                best = node
            end
        end
    end)

    return best
end

function M.trim_whitespace(bufnr, range)
    bufnr = normalize_bufnr(bufnr)
    local start_row = range.start_row
    local start_col = range.start_col
    local end_row = range.end_row
    local end_col = range.end_col

    while
        start_row < end_row or (start_row == end_row and start_col < end_col)
    do
        local line = vim.api.nvim_buf_get_lines(
            bufnr,
            start_row,
            start_row + 1,
            false
        )[1] or ""
        local limit = start_row == end_row and end_col or #line
        local segment = line:sub(start_col + 1, limit)
        local first = segment:find("%S")

        if first then
            start_col = start_col + first - 1
            break
        end

        start_row = start_row + 1
        start_col = 0
    end

    local row = end_row
    local col = end_col
    while row > start_row or (row == start_row and col > start_col) do
        if col == 0 then
            row = row - 1
            col = #(
                vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
            )
        end

        local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
            or ""
        local prefix = line:sub(1, col)
        local found = nil
        for index = #prefix, 1, -1 do
            if not prefix:sub(index, index):match("%s") then
                found = index
                break
            end
        end

        if found then
            end_row = row
            end_col = found
            break
        end

        col = 0
    end

    if
        start_row > end_row or (start_row == end_row and start_col >= end_col)
    then
        return nil
    end

    return {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
    }
end

function M.inclusive_end(bufnr, range)
    bufnr = normalize_bufnr(bufnr)
    local row = range.end_row
    local col = range.end_col

    while row >= range.start_row do
        if col > 0 then
            return row, col - 1
        end

        row = row - 1
        if row >= range.start_row then
            col = #(
                vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
            )
        end
    end

    return nil
end

function M.select_range(bufnr, range)
    bufnr = normalize_bufnr(bufnr)
    local end_row, end_col = M.inclusive_end(bufnr, range)
    if not end_row then
        return false
    end

    local winid = windows.for_buffer(bufnr)
    if not winid then
        return false
    end
    vim.api.nvim_set_current_win(winid)

    local mode = vim.fn.mode(1)
    if mode == "v" or mode == "V" or mode == "\22" then
        vim.cmd("normal! \27")
    end

    vim.api.nvim_win_set_cursor(winid, { range.start_row + 1, range.start_col })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(winid, { end_row + 1, end_col })
    return true
end

function M.node_id(node)
    if type(node.id) == "function" then
        local ok, id = pcall(node.id, node)
        if ok and id ~= nil then
            return tostring(id)
        end
    end
end

function M.syntax_signature(bufnr, root)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local id = M.node_id(root)
    if id then
        return ("tick:%d:node:%s"):format(changedtick, id)
    end

    local start_row, start_col, end_row, end_col = root:range()
    return ("tick:%d:%d:%d:%d:%d:%d"):format(
        changedtick,
        start_row,
        start_col,
        end_row,
        end_col,
        M.named_child_count(root)
    )
end

function M.position_leq(left_row, left_col, right_row, right_col)
    return left_row < right_row
        or (left_row == right_row and left_col <= right_col)
end

function M.collect_error_ranges(node, ranges, limit)
    ranges = ranges or {}
    if not node then
        return ranges
    end

    local node_range = M.range(node)
    if limit and not M.overlaps(node_range, limit) then
        return ranges
    end

    if node:type() == "ERROR" then
        if node_range.end_row > node_range.start_row then
            node_range.end_row = node_range.start_row + 1
            node_range.end_col = 0
        end
        ranges[#ranges + 1] = node_range
        return ranges
    end

    for _, child in ipairs(M.children(node)) do
        M.collect_error_ranges(child, ranges, limit)
    end
    return ranges
end

function M.intersects_error_range(range, error_ranges)
    for _, error_range in ipairs(error_ranges or {}) do
        if M.overlaps(range, error_range) then
            return true
        end
    end
    return false
end

return M
