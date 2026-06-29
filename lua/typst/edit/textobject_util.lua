local cursor = require("typst.edit.cursor")
local ts = require("typst.core.treesitter")

local M = {}

function M.range_size(range)
    return ts.range_size(range)
end

function M.contains_range(range, row, col)
    return ts.contains_range(range, row, col)
end

function M.window_for_buffer(bufnr)
    return cursor.window_for_buffer(bufnr)
end

function M.cursor_position(pos, bufnr)
    if pos then
        return pos[1], pos[2]
    end

    return cursor.row_col(bufnr)
end

function M.line_text(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

return M
