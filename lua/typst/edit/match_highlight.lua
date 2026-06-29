local config = require("typst.config")
local matchparen = require("typst.edit.matchparen")

local M = {}

local ns = vim.api.nvim_create_namespace("typst_nvim_matchparen")
local enabled = {}
local provider_registered = false

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function mark(bufnr, token, ephemeral)
    if not token then
        return
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, token.row, token.col, {
        end_col = token.end_col,
        hl_group = "MatchParen",
        ephemeral = ephemeral == true,
    })
end

local function render(bufnr, winid, ephemeral)
    if
        not enabled[bufnr]
        or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return false
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local target = matchparen.target({ bufnr = bufnr, cursor = cursor })
    if not target then
        return false
    end

    mark(bufnr, target.token, ephemeral)
    mark(bufnr, target.match, ephemeral)
    return true
end

local function register_provider()
    if provider_registered then
        return
    end
    provider_registered = true

    vim.api.nvim_set_decoration_provider(ns, {
        on_win = function(_, winid, bufnr)
            if not enabled[bufnr] then
                return false
            end
            render(bufnr, winid, true)
            return true
        end,
    })
end

function M.enable(bufnr)
    bufnr = normalize_bufnr(bufnr)
    enabled[bufnr] = true
    register_provider()
    M.refresh(bufnr)
    return true
end

function M.disable(bufnr)
    bufnr = normalize_bufnr(bufnr)
    enabled[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
    return true
end

function M.toggle(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if enabled[bufnr] then
        M.disable(bufnr)
        return false
    end
    M.enable(bufnr)
    return true
end

function M.is_enabled(bufnr)
    return enabled[normalize_bufnr(bufnr)] == true
end

function M.refresh(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return 0
    end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local count = 0
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if render(bufnr, winid, false) then
            count = count + 1
        end
    end
    return count
end

function M.apply(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if config.unsafe_get().matchparen.enabled then
        return M.enable(bufnr)
    end
    return false
end

function M.detach(bufnr)
    return M.disable(bufnr)
end

function M.namespace()
    return ns
end

function M.reset()
    enabled = {}
end

return M
