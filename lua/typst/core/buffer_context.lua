local buffer = require("typst.core.buffer")
local util = require("typst.core.util")

local M = {}

local function valid_win(winid)
    return type(winid) == "number" and vim.api.nvim_win_is_valid(winid)
end

local function buffer_path(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    return path ~= "" and util.normalize(path) or nil
end

--- Resolve common current-buffer context without mutating project state.
---@param opts? table Options with optional `bufnr`, `winid`, and `project`.
---@return table context Buffer/window/path context.
function M.current(opts)
    opts = opts or {}
    local bufnr = buffer.normalize_bufnr(opts.bufnr)
    local candidate_winid = valid_win(opts.winid) and opts.winid
        or vim.api.nvim_get_current_win()
    local winid
    if
        valid_win(candidate_winid)
        and vim.api.nvim_win_get_buf(candidate_winid) == bufnr
    then
        winid = candidate_winid
    end

    local path = buffer_path(bufnr)
    local project = type(opts.project) == "table" and opts.project or nil
    local file_dir = path and util.dirname(path)
        or (project and project.main and util.dirname(project.main))
        or vim.fn.getcwd()
    return {
        bufnr = bufnr,
        winid = winid,
        path = path,
        file_dir = file_dir,
        project = project,
    }
end

function M.file_dir(opts)
    return M.current(opts).file_dir
end

return M
