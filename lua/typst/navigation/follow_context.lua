local lexical = require("typst.syntax.lexical")
local position = require("typst.completion.position")
local project_context = require("typst.project.context")
local util = require("typst.core.util")

local M = {}

---@class TypstFollowTarget
---@field kind string
---@field path string
---@field lnum number
---@field col number
---@field provider string
---@field name string?
---@field spec string?
---@field semantic boolean?

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.cursor_position(opts)
    opts = opts or {}
    local resolved = position.resolve(opts)
    if not resolved then
        return nil, nil
    end
    return resolved.row, resolved.col
end

function M.project_for(bufnr)
    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

function M.line_at(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function lexical_context_at(bufnr, row, col)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
    return lexical.context_at(lines, row, col)
end

function M.source_context_at(bufnr, row, col)
    local context = lexical_context_at(bufnr, row, col)
    return {
        code = context == "code",
        string = context == "string",
        comment = context == "comment",
        raw = context == "raw",
    }
end

function M.source_base(bufnr, project)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path ~= "" then
        return util.dirname(path)
    end

    return project and project.root or vim.fn.getcwd()
end

function M.buffer_path(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    return path ~= "" and util.normalize(path) or nil
end

local function project_buffer_path(project, bufnr)
    local path = M.buffer_path(bufnr)
    if path then
        return path
    end

    local resolution = project
        and project.resolutions
        and project.resolutions[bufnr]
    if resolution and resolution.scratch then
        return project.main
    end
end

function M.buffer_for_project_path(project, path)
    if not path then
        return nil
    end

    for bufnr in pairs(project and project.bufs or {}) do
        if
            vim.api.nvim_buf_is_valid(bufnr)
            and util.same_path(project_buffer_path(project, bufnr), path)
        then
            return bufnr
        end
    end

    local bufnr = util.loaded_buffer_for_path(path) or vim.fn.bufnr(path)
    if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
        return bufnr
    end
end

function M.target_location(kind, location, extra)
    if not location or not location.path then
        return nil
    end

    return vim.tbl_extend("force", extra or {}, {
        kind = kind,
        path = location.path,
        lnum = location.lnum or 1,
        col = location.col or 1,
        provider = location.provider or "project",
    })
end

return M
