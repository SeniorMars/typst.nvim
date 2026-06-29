local config = require("typst.config")
local custom = require("typst.conceal.custom")
local matches = require("typst.conceal.matches")
local metadata = require("typst.metadata")
local reveal = require("typst.conceal.reveal")
local telemetry = require("typst.core.telemetry")

local M = {}

local window_cache = {}

local function cache_key(bufnr, winid, start_row, end_row)
    return table.concat({
        bufnr,
        winid,
        vim.api.nvim_buf_get_changedtick(bufnr),
        start_row,
        end_row,
        matches.generation(),
        config.generation(),
        metadata.generation(),
        custom.generation(),
    }, "\0")
end

local function collected_matches(bufnr, winid, opts, custom_conceal)
    local start_row = opts.start_row or 0
    local end_row = opts.end_row or vim.api.nvim_buf_line_count(bufnr)
    local key = cache_key(bufnr, winid, start_row, end_row)
    local cached = window_cache[winid]
    if cached and cached.key == key then
        telemetry.record("conceal.render.cache_hit", 0, {
            bufnr = bufnr,
            winid = winid,
        })
        return cached.matches
    end

    telemetry.record("conceal.render.cache_miss", 0, {
        bufnr = bufnr,
        winid = winid,
    })
    local collected = matches.matches(
        bufnr,
        { start_row = start_row, end_row = end_row },
        custom_conceal
    )
    window_cache[winid] = {
        key = key,
        bufnr = bufnr,
        matches = collected,
    }
    return collected
end

function M.window_matches(bufnr, winid, opts, custom_conceal)
    opts = opts or {}
    local conceal_opts = opts.conceal_opts or config.unsafe_get().conceal
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return reveal.filter(
        collected_matches(bufnr, winid, opts, custom_conceal),
        conceal_opts,
        cursor[1] - 1,
        cursor[2]
    )
end

function M.apply(bufnr, winid, namespace, opts, custom_conceal)
    local count = 0
    for _, match in ipairs(M.window_matches(bufnr, winid, opts, custom_conceal)) do
        vim.api.nvim_buf_set_extmark(
            bufnr,
            namespace,
            match.source.start_row,
            match.source.start_col,
            {
                end_row = match.source.end_row,
                end_col = match.source.end_col,
                conceal = match.replacement,
                ephemeral = true,
                priority = 120,
            }
        )
        count = count + 1
    end

    telemetry.record("conceal.render.extmarks", count, {
        bufnr = bufnr,
        winid = winid,
    })
    return count
end

function M.forget(bufnr)
    if not bufnr then
        window_cache = {}
        return
    end

    for winid, entry in pairs(window_cache) do
        if entry.bufnr == bufnr then
            window_cache[winid] = nil
        end
    end
end

function M.forget_window(winid)
    window_cache[winid] = nil
end

function M.invalidate_ranges(bufnr, ranges)
    matches.invalidate_ranges(bufnr, ranges)
    M.forget(bufnr)
end

function M.reset()
    window_cache = {}
end

return M
