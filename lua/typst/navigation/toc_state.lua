local util = require("typst.core.util")
local async = require("typst.core.async")

local M = {}

local toc_windows = {}

function M.project_key(project)
    return project.key or project.main
end

function M.valid_win(winid)
    return type(winid) == "number"
        and winid > 0
        and vim.api.nvim_win_is_valid(winid)
end

function M.valid_buf(bufnr)
    return type(bufnr) == "number"
        and bufnr > 0
        and vim.api.nvim_buf_is_valid(bufnr)
end

function M.title(project)
    return ("typst.nvim TOC: %s"):format(
        util.relpath(project.main, project.root)
    )
end

function M.for_project(project)
    local key = M.project_key(project)
    toc_windows[key] = toc_windows[key] or {}
    return toc_windows[key]
end

function M.by_key(key)
    return toc_windows[key]
end

function M.close_timer(timer)
    async.close_timer(timer)
end

function M.is_toc_buffer(bufnr)
    return M.valid_buf(bufnr) and vim.b[bufnr].typst_toc == true
end

function M.any_open()
    for _, state in pairs(toc_windows) do
        if M.valid_win(state.winid) then
            return true
        end
    end
    return false
end

function M.close_window(state)
    M.close_timer(state.refresh_timer)
    state.refresh_timer = nil
    M.close_timer(state.follow_timer)
    state.follow_timer = nil
    state.follow_bufnr = nil

    if not M.valid_win(state.winid) then
        return false
    end

    local winid = state.winid
    state.winid = nil
    pcall(vim.api.nvim_win_close, winid, true)
    return true
end

return M
