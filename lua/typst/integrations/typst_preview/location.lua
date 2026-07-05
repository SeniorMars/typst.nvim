local open_helper = require("typst.core.open")
local position = require("typst.completion.position")
local util = require("typst.core.util")

local M = {}

--- Return the source position for preview synchronization.
---@param opts? table Position options with optional line and column.
---@return table? position One-based line and column.
function M.current_position(opts)
    opts = opts or {}
    if opts.line or opts.column then
        return {
            line = opts.line or vim.fn.line("."),
            column = opts.column or vim.fn.col("."),
        }
    end

    local resolved = position.resolve(opts)
    if resolved then
        return {
            line = resolved.row + 1,
            column = resolved.col + 1,
        }
    end

    if opts.bufnr ~= nil or opts.winid ~= nil or opts.pos ~= nil then
        return nil
    end

    return {
        line = vim.fn.line("."),
        column = vim.fn.col("."),
    }
end

--- Resolve preview inverse-search options into a source location.
---@param project table Project state used for root-relative source paths.
---@param opts? table Inverse-search options.
---@return table location Source location with path, line, column, and output.
function M.from_opts(project, opts)
    opts = opts or {}
    local path = opts.path or opts.file or opts.filename or project.main
    path = util.resolve_path(path, project.root)
    return {
        path = path,
        line = tonumber(opts.line) or 1,
        column = tonumber(opts.column) or 1,
    }
end

--- Clamp a byte column to a valid UTF-8 boundary in a line.
---@param text string Line text.
---@param col integer Zero-based byte column.
---@return integer col Clamped zero-based byte column.
function M.clamp_byte_col(text, col)
    text = text or ""
    col = math.max(math.min(tonumber(col) or 0, #text), 0)

    local ok, char_index = pcall(vim.str_utfindex, text, col)
    if not ok or type(char_index) ~= "number" then
        return col
    end

    local boundary_ok, boundary = pcall(vim.str_byteindex, text, char_index)
    if boundary_ok and type(boundary) == "number" and boundary <= col then
        return boundary
    end

    if char_index > 0 then
        boundary_ok, boundary = pcall(vim.str_byteindex, text, char_index - 1)
        if boundary_ok and type(boundary) == "number" then
            return boundary
        end
    end

    return 0
end

--- Open a preview source location in Neovim.
---@param location table Source location with path, line, and column.
---@param opts? table Open options.
---@return table result Open result or failure payload.
function M.open_source(location, opts)
    if opts and opts.open == false then
        return location
    end

    local opened, err = open_helper.file(location.path, opts)
    if not opened then
        return {
            ok = false,
            reason = "open_failed",
            message = ("Failed to open preview source: %s"):format(
                err or "unknown error"
            ),
            path = location.path,
        }
    end

    local line_count = vim.api.nvim_buf_line_count(opened.bufnr)
    local line = math.min(math.max(location.line, 1), line_count)
    local text = vim.api.nvim_buf_get_lines(opened.bufnr, line - 1, line, false)[1]
        or ""
    local column = M.clamp_byte_col(text, location.column - 1)
    vim.api.nvim_win_set_cursor(opened.winid, { line, column })
    return location
end

return M
