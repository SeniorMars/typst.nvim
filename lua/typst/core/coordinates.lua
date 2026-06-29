local util = require("typst.core.util")

local M = {}

-- Internal coordinate contract:
--   row: zero-based buffer line
--   byte_col: zero-based UTF-8 byte offset inside that line
-- Convert to LSP client offsets only at LSP boundaries.

function M.line_text(bufnr, row)
    local ok, lines =
        pcall(vim.api.nvim_buf_get_lines, bufnr, row, row + 1, false)
    if not ok or type(lines) ~= "table" then
        return ""
    end
    return lines[1] or ""
end

function M.line_before_cursor(bufnr, row, col, opts)
    opts = opts or {}
    col = math.max(tonumber(col) or 0, 0)
    if opts.include_cursor then
        col = col + 1
    end
    return M.line_text(bufnr, row):sub(1, col)
end

function M.line_text_for_file(path, row)
    if path then
        local loaded = util.loaded_buffer_for_path(path)
        if loaded then
            return M.line_text(loaded, row)
        end

        if vim.fn.filereadable(path) == 1 then
            local ok, lines = pcall(vim.fn.readfile, path, "", row + 1)
            if ok and lines then
                return lines[row + 1] or ""
            end
        end
    end

    return ""
end

function M.byte_col_to_lsp_character(bufnr, row, byte_col, encoding)
    encoding = encoding or "utf-16"
    byte_col = byte_col or 0
    if encoding == "utf-8" then
        return byte_col
    end

    local ok, character =
        pcall(vim.str_utfindex, M.line_text(bufnr, row), encoding, byte_col)
    if ok and type(character) == "number" then
        return character
    end

    return byte_col
end

function M.lsp_character_to_byte_col(text, character, encoding)
    encoding = encoding or "utf-16"
    character = character or 0
    if encoding == "utf-8" then
        return character
    end

    local ok, byte_col =
        pcall(vim.str_byteindex, text or "", encoding, character, false)
    if ok and type(byte_col) == "number" then
        return byte_col
    end

    return character
end

function M.buffer_lsp_character_to_byte_col(bufnr, row, character, encoding)
    return M.lsp_character_to_byte_col(
        M.line_text(bufnr, row),
        character,
        encoding
    )
end

function M.file_lsp_character_to_byte_col(path, row, character, encoding)
    return M.lsp_character_to_byte_col(
        M.line_text_for_file(path, row),
        character,
        encoding
    )
end

function M.symbol_byte_col(bufnr, path, row, character, encoding)
    if path then
        return M.file_lsp_character_to_byte_col(path, row, character, encoding)
    end
    return M.buffer_lsp_character_to_byte_col(bufnr, row, character, encoding)
end

function M.explicit_position(bufnr, client, pos)
    if not pos then
        return nil
    end

    local row = pos[1]
    return {
        line = row,
        character = M.byte_col_to_lsp_character(
            bufnr,
            row,
            pos[2],
            client.offset_encoding or "utf-16"
        ),
    }
end

function M.window_for_buffer(bufnr)
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

function M.current_position(bufnr, client)
    local encoding = client.offset_encoding or "utf-16"
    if vim.api.nvim_get_current_buf() == bufnr then
        local ok, params = pcall(vim.lsp.util.make_position_params, 0, encoding)
        if ok and params and params.position then
            return params.position
        end
    end

    local winid = M.window_for_buffer(bufnr)
    if not winid then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    return {
        line = cursor[1] - 1,
        character = M.byte_col_to_lsp_character(
            bufnr,
            cursor[1] - 1,
            cursor[2],
            encoding
        ),
    }
end

function M.position_params(bufnr, client, opts)
    opts = opts or {}
    local resolved = opts.position
        or M.explicit_position(bufnr, client, opts.pos)
        or M.current_position(bufnr, client)
    if not resolved then
        return nil
    end

    return {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = resolved,
    }
end

function M.current_range(bufnr, client)
    local encoding = client.offset_encoding or "utf-16"
    if vim.api.nvim_get_current_buf() == bufnr then
        local ok, params = pcall(vim.lsp.util.make_range_params, 0, encoding)
        if ok and params then
            return params.range
        end
    end

    local winid = M.window_for_buffer(bufnr)
    if not winid then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local position = {
        line = cursor[1] - 1,
        character = M.byte_col_to_lsp_character(
            bufnr,
            cursor[1] - 1,
            cursor[2],
            encoding
        ),
    }

    return {
        start = position,
        ["end"] = position,
    }
end

return M
