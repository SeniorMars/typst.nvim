local M = {}

local edit_context = require("typst.edit.context")
local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.window_for_buffer(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == bufnr then
        return current
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if
            vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == bufnr
        then
            return winid
        end
    end
end

function M.pos(bufnr, opts)
    if
        opts
        and (
            opts.bufnr ~= nil
            or opts.winid ~= nil
            or opts.pos ~= nil
            or opts.row ~= nil
            or opts.col ~= nil
        )
    then
        if opts.pos then
            return opts.pos
        end
        local ctx = edit_context.resolve(
            vim.tbl_extend("force", opts, { bufnr = bufnr }),
            { require_position = true }
        )
        return ctx and { ctx.row, ctx.col } or nil
    end

    local winid = M.window_for_buffer(bufnr)
    if not winid then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    return { cursor[1] - 1, cursor[2] }
end

function M.row_col(bufnr, opts)
    local pos = M.pos(bufnr, opts)
    if not pos then
        return nil, nil
    end
    return pos[1], pos[2]
end

return M
