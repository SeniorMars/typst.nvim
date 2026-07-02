local M = {}

local edit_context = require("typst.edit.context")
local windows = require("typst.core.windows")

function M.window_for_buffer(bufnr)
    return windows.for_buffer(bufnr)
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
