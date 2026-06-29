local buffer = require("typst.core.buffer")

local M = {}

local function line_at(bufnr, row)
    local ok, lines =
        pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
    if not ok then
        return nil
    end
    return lines[1]
end

local function window_for_opts(opts, bufnr)
    if opts.winid and vim.api.nvim_win_is_valid(opts.winid) then
        if vim.api.nvim_win_get_buf(opts.winid) == bufnr then
            return opts.winid
        end
        return nil
    end

    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == bufnr then
        return current
    end
end

function M.window_for_buffer(bufnr, opts)
    bufnr = buffer.normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    return window_for_opts(opts or {}, bufnr)
end

function M.clamp_position(bufnr, row, col)
    local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
    row = math.max(0, math.min(tonumber(row) or 0, line_count - 1))
    local line = line_at(bufnr, row) or ""
    col = math.max(0, math.min(tonumber(col) or 0, #line))
    return row, col
end

--- Resolve an edit target from API/mapping action options.
---@param opts? table Options with `bufnr`, `winid`, `pos`, `row`, and/or `col`.
---@param policy? table Resolver policy. `require_position` defaults to true.
---@return table? ctx Resolved edit context.
---@return string? reason Machine-readable failure reason.
function M.resolve(opts, policy)
    opts = opts or {}
    policy = policy or {}
    local require_position = policy.require_position ~= false

    local bufnr
    if
        (opts.bufnr == nil or opts.bufnr == 0)
        and opts.winid
        and vim.api.nvim_win_is_valid(opts.winid)
    then
        bufnr = vim.api.nvim_win_get_buf(opts.winid)
    else
        bufnr = buffer.normalize_bufnr(opts.bufnr)
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid_buffer"
    end

    local winid = window_for_opts(opts, bufnr)
    local row, col
    if opts.pos then
        row, col = opts.pos[1], opts.pos[2]
    elseif winid then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        row, col = cursor[1] - 1, cursor[2]
    end
    if opts.row ~= nil then
        row = opts.row
    end
    if opts.col ~= nil then
        col = opts.col
    end

    if row == nil or col == nil then
        if require_position then
            return nil, "position_required"
        end
        row, col = 0, 0
    end

    row, col = M.clamp_position(bufnr, row, col)
    return {
        bufnr = bufnr,
        winid = winid,
        row = row,
        col = col,
        line = line_at(bufnr, row) or "",
    }
end

function M.set_cursor(ctx, row, col)
    if
        not ctx
        or not ctx.winid
        or not vim.api.nvim_win_is_valid(ctx.winid)
        or vim.api.nvim_win_get_buf(ctx.winid) ~= ctx.bufnr
    then
        return false
    end

    row, col = M.clamp_position(ctx.bufnr, row, col)
    vim.api.nvim_win_set_cursor(ctx.winid, { row + 1, col })
    return true
end

return M
