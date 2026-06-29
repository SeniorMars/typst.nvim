local config = require("typst.config")
local custom = require("typst.conceal.custom")
local conceal_util = require("typst.conceal.util")
local inspect = require("typst.conceal.inspect")
local log = require("typst.core.log")
local matches = require("typst.conceal.matches")
local metadata = require("typst.metadata")
local project = require("typst.project")
local render = require("typst.conceal.render")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

M.namespace = vim.api.nvim_create_namespace("typst.nvim.conceal")

local provider_started = false
local saved_conceallevel = {}
local installed_conceallevel = {}

-- Conceal is window-local in Neovim, but the feature is configured per Typst
-- buffer. Track only windows where typst.nvim changed conceallevel, then restore
-- them if the user disables conceal, closes the buffer, or resets the plugin.
local range_contains = conceal_util.range_contains

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function line_count(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
end

local function conceal_config()
    return config.unsafe_get().conceal
end

local function buffer_enabled(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local override = vim.b[bufnr].typst_conceal_enabled
    if type(override) == "boolean" then
        return override
    end

    return conceal_config().enabled
end

local function is_typst_buffer(bufnr)
    return vim.bo[bufnr].filetype == "typst" or project.get(bufnr) ~= nil
end

function M.matches(bufnr, opts)
    bufnr = normalize_bufnr(bufnr)
    return telemetry.time("conceal.matches", function()
        return matches.matches(bufnr, opts, custom.all())
    end)
end

local function match_under_cursor(bufnr, winid)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local row = cursor[1] - 1
    local col = cursor[2]
    for _, match in
        ipairs(M.matches(bufnr, { start_row = row, end_row = row + 1 }))
    do
        if
            range_contains(match.reveal, row, col)
            or range_contains(match.source, row, col)
        then
            return match
        end
    end
end

function M._window_matches(bufnr, winid, opts)
    bufnr = normalize_bufnr(bufnr)
    winid = winid or vim.api.nvim_get_current_win()
    if
        not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return {}
    end

    return render.window_matches(bufnr, winid, opts, custom.all())
end

local function restore_conceallevel(winid)
    local previous = saved_conceallevel[winid]
    if previous ~= nil and vim.api.nvim_win_is_valid(winid) then
        local installed = installed_conceallevel[winid]
        if installed == nil or vim.wo[winid].conceallevel == installed then
            vim.wo[winid].conceallevel = previous
        end
    end
    saved_conceallevel[winid] = nil
    installed_conceallevel[winid] = nil
end

---Drop stale conceallevel bookkeeping for closed windows.
local function prune_conceallevels()
    for winid in pairs(saved_conceallevel) do
        if not vim.api.nvim_win_is_valid(winid) then
            saved_conceallevel[winid] = nil
            installed_conceallevel[winid] = nil
        end
    end
end

local function restore_buffer_conceallevel(bufnr)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if
            vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == bufnr
        then
            restore_conceallevel(winid)
        end
    end
end

local function maybe_set_conceallevel(winid)
    prune_conceallevels()
    local opts = conceal_config()
    if opts.conceallevel <= 0 then
        restore_conceallevel(winid)
        return
    end

    if saved_conceallevel[winid] == nil then
        saved_conceallevel[winid] = vim.wo[winid].conceallevel
    end
    vim.wo[winid].conceallevel = opts.conceallevel
    installed_conceallevel[winid] = opts.conceallevel
end

function M.apply(bufnr, winid)
    bufnr = normalize_bufnr(bufnr)
    winid = winid or vim.api.nvim_get_current_win()
    if
        not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return false
    end

    if not buffer_enabled(bufnr) or not is_typst_buffer(bufnr) then
        restore_conceallevel(winid)
        return false
    end

    M.start()
    maybe_set_conceallevel(winid)
    return true
end

local function render_window(winid, bufnr, topline, botline)
    if not is_typst_buffer(bufnr) or not buffer_enabled(bufnr) then
        return false
    end

    local opts = conceal_config()
    local margin = opts.viewport_margin or 0
    local start_row = math.max(0, topline - margin)
    local end_row = math.min(line_count(bufnr), botline + margin)

    render.apply(bufnr, winid, M.namespace, {
        start_row = start_row,
        end_row = end_row,
        conceal_opts = opts,
    }, custom.all())

    return true
end

---Render conceal extmarks on redraw via a shared decoration provider.
function M.start()
    if provider_started then
        return
    end

    -- Decoration providers produce ephemeral extmarks during redraw. This keeps
    -- conceal responsive to cursor reveal rules without storing thousands of
    -- persistent extmarks in large documents.
    vim.api.nvim_set_decoration_provider(M.namespace, {
        on_win = function(_, winid, bufnr, topline, botline)
            local ok, result = telemetry.time("conceal.on_win", function()
                return pcall(render_window, winid, bufnr, topline, botline)
            end)
            if not ok then
                log.add(
                    "warn",
                    "conceal render failed",
                    { error = result, bufnr = bufnr }
                )
                return false
            end
            return result
        end,
    })

    provider_started = true
end

local function refresh(bufnr)
    matches.refresh(bufnr)
    render.forget(bufnr)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
    end
    pcall(vim.cmd.redraw)
end

function M.enable(bufnr)
    bufnr = normalize_bufnr(bufnr)
    vim.b[bufnr].typst_conceal_enabled = true
    M.start()
    M.apply(bufnr)
    refresh(bufnr)
    return true
end

function M.disable(bufnr)
    bufnr = normalize_bufnr(bufnr)
    vim.b[bufnr].typst_conceal_enabled = false
    restore_buffer_conceallevel(bufnr)
    refresh(bufnr)
    return true
end

function M.detach(bufnr)
    bufnr = normalize_bufnr(bufnr)
    restore_buffer_conceallevel(bufnr)
    matches.forget(bufnr)
    render.forget(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        util.del_buf_var(bufnr, "typst_conceal_enabled")
        vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
    end
    return true
end

function M.toggle(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if buffer_enabled(bufnr) then
        M.disable(bufnr)
        return false
    end

    M.enable(bufnr)
    return true
end

function M.refresh(bufnr)
    bufnr = normalize_bufnr(bufnr)
    refresh(bufnr)
    return true
end

function M.register(kind, name, replacement)
    replacement = custom.register(kind, name, replacement)
    refresh(nil)
    return replacement
end

function M.unregister(kind, name)
    local replacement = custom.unregister(kind, name)
    refresh(nil)
    return replacement
end

function M.custom(kind)
    return custom.get(kind)
end

function M.inspect(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local winid = opts.winid or vim.api.nvim_get_current_win()
    local match = opts.match or match_under_cursor(bufnr, winid)
    return inspect.inspect(bufnr, match)
end

function M.is_enabled(bufnr)
    return buffer_enabled(bufnr)
end

function M.generation()
    return matches.generation()
end

function M._forget_window(winid)
    winid = tonumber(winid)
    if not winid then
        return false
    end

    local had_saved = saved_conceallevel[winid] ~= nil
    saved_conceallevel[winid] = nil
    installed_conceallevel[winid] = nil
    render.forget_window(winid)
    return had_saved
end

---Reset global conceal state, extmarks, and tracked configuration.
function M.reset()
    pcall(vim.api.nvim_set_decoration_provider, M.namespace, {})
    matches.reset()
    render.reset()
    for winid in pairs(saved_conceallevel) do
        if vim.api.nvim_win_is_valid(winid) then
            local installed = installed_conceallevel[winid]
            if installed == nil or vim.wo[winid].conceallevel == installed then
                vim.wo[winid].conceallevel = saved_conceallevel[winid]
            end
        end
    end
    saved_conceallevel = {}
    installed_conceallevel = {}
    custom.reset()
    metadata.reset()
    provider_started = false
end

return M
