local M = {}

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function line_at(bufnr, row)
    local ok, lines =
        pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
    if not ok then
        return nil
    end
    return lines[1]
end

function M.resolve(opts, bufnr)
    opts = opts or {}
    if
        (bufnr == nil or bufnr == 0)
        and (opts.bufnr == nil or opts.bufnr == 0)
        and opts.winid
        and vim.api.nvim_win_is_valid(opts.winid)
    then
        bufnr = vim.api.nvim_win_get_buf(opts.winid)
    else
        bufnr = M.normalize_bufnr(bufnr or opts.bufnr)
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local row, col
    if opts.pos then
        row, col = opts.pos[1], opts.pos[2]
    elseif opts.winid and vim.api.nvim_win_is_valid(opts.winid) then
        if vim.api.nvim_win_get_buf(opts.winid) == bufnr then
            local cursor = vim.api.nvim_win_get_cursor(opts.winid)
            row, col = cursor[1] - 1, cursor[2]
        end
    elseif vim.api.nvim_get_current_buf() == bufnr then
        local cursor = vim.api.nvim_win_get_cursor(0)
        row, col = cursor[1] - 1, cursor[2]
    end

    if row == nil or col == nil then
        return nil
    end

    local line = opts.line or line_at(bufnr, row)
    if not line then
        return nil
    end

    return {
        bufnr = bufnr,
        row = row,
        col = col,
        line = line,
    }
end

return M
