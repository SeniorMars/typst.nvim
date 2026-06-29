local conceal_util = require("typst.conceal.util")

local M = {}

local range_contains = conceal_util.range_contains

local function mode()
    local current = vim.api.nvim_get_mode()
    return current and current.mode or "n"
end

local function row_intersects(range, row)
    local start_row = range.start_row or 0
    local end_row = range.end_row or start_row
    if end_row > start_row and (range.end_col or 0) == 0 then
        end_row = end_row - 1
    end
    return row >= start_row and row <= end_row
end

local function policy_for(match, opts)
    opts = opts or {}
    local policy = opts.reveal
    if mode():sub(1, 1) == "i" and opts.reveal_insert ~= nil then
        policy = opts.reveal_insert
    end

    local by_category = opts.reveal_by_category or {}
    return by_category[match.category] or policy or "node"
end

function M.should_reveal(match, opts, cursor_row, cursor_col)
    local policy = policy_for(match, opts)
    if policy == "none" then
        return false
    end

    if policy == "line" then
        return row_intersects(match.reveal or match.source, cursor_row)
            or row_intersects(match.source, cursor_row)
    end

    return range_contains(match.reveal or match.source, cursor_row, cursor_col)
        or range_contains(match.source, cursor_row, cursor_col)
end

function M.filter(matches, opts, cursor_row, cursor_col)
    local filtered = {}
    for _, match in ipairs(matches or {}) do
        if not M.should_reveal(match, opts, cursor_row, cursor_col) then
            filtered[#filtered + 1] = match
        end
    end
    return filtered
end

return M
