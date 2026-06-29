local config = require("typst.config")
local match_query = require("typst.conceal.match_query")
local conceal_util = require("typst.conceal.util")
local shadows = require("typst.conceal.shadows")
local telemetry = require("typst.core.telemetry")

local M = {}

local cache = {}
local generation = 0
local MATCH_CHUNK_LINES = 128

-- Conceal queries are expensive on large documents. Cache by changedtick,
-- explicit generation, and conceal config, then split by line chunks so redraw
-- only recomputes the visible neighborhood.
local range_contains = conceal_util.range_contains

local function line_count(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
end

local function conceal_config()
    return config.unsafe_get().conceal
end

-- Build a deterministic signature for config values (order-insensitive by key sort).
local function append_signature(parts, value)
    local value_type = type(value)
    if value_type ~= "table" then
        parts[#parts + 1] = value_type
        parts[#parts + 1] = tostring(value)
        return
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)

    parts[#parts + 1] = "{"
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key)
        parts[#parts + 1] = "="
        append_signature(parts, value[key])
        parts[#parts + 1] = ";"
    end
    parts[#parts + 1] = "}"
end

local function conceal_signature(opts)
    local parts = {}
    append_signature(parts, opts)
    return table.concat(parts)
end

local function cache_entry(bufnr)
    local opts = conceal_config()
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local config_signature = conceal_signature(opts)
    local entry = cache[bufnr]
    if
        entry
        and entry.changedtick == changedtick
        and entry.generation == generation
        and entry.config_signature == config_signature
    then
        return entry
    end

    entry = {
        changedtick = changedtick,
        generation = generation,
        config_signature = config_signature,
        chunks = {},
    }
    cache[bufnr] = entry

    return entry
end

local function chunk_start_for(row)
    return math.floor(math.max(row, 0) / MATCH_CHUNK_LINES) * MATCH_CHUNK_LINES
end

local function chunk_matches(bufnr, entry, chunk_start, custom_conceal)
    local total = line_count(bufnr)
    local chunk_end = math.min(total, chunk_start + MATCH_CHUNK_LINES)
    local key = ("%d:%d"):format(chunk_start, chunk_end)
    if entry.chunks[key] then
        telemetry.record("conceal.chunk_cache.hit", 0, {
            bufnr = bufnr,
            chunk_start = chunk_start,
            chunk_end = chunk_end,
        })
        return entry.chunks[key]
    end
    telemetry.record("conceal.chunk_cache.miss", 0, {
        bufnr = bufnr,
        chunk_start = chunk_start,
        chunk_end = chunk_end,
    })

    -- Query one line beyond each chunk so multi-line nodes crossing the viewport
    -- edge still produce stable conceal matches.
    local query_start = math.max(0, chunk_start - 1)
    local query_end = math.min(total, chunk_end + 1)
    local matches, cacheable =
        match_query.query(bufnr, query_start, query_end, custom_conceal)
    if cacheable ~= false then
        entry.chunks[key] = matches
    end
    return matches
end

local function range_matches_cached(bufnr, start_row, end_row, custom_conceal)
    start_row = math.max(0, start_row)
    local total = line_count(bufnr)
    if end_row < 0 then
        end_row = total
    end
    end_row = math.min(total, end_row)

    if end_row <= start_row then
        return {}
    end

    local entry = cache_entry(bufnr)
    local matches = {}
    local chunk_start = chunk_start_for(start_row)
    while chunk_start < end_row do
        for _, match in
            ipairs(chunk_matches(bufnr, entry, chunk_start, custom_conceal))
        do
            if
                match.source.end_row >= start_row
                and match.source.start_row < end_row
            then
                matches[#matches + 1] = match
            end
        end
        chunk_start = chunk_start + MATCH_CHUNK_LINES
    end

    return match_query.filter_overlaps(matches)
end

function M.matches(bufnr, opts, custom_conceal)
    opts = opts or {}
    local start_row = opts.start_row or 0
    local end_row = opts.end_row or line_count(bufnr)

    return range_matches_cached(bufnr, start_row, end_row, custom_conceal)
end

function M.window(bufnr, winid, opts, custom_conceal)
    opts = opts or {}
    local conceal_opts = opts.conceal_opts or conceal_config()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local cursor_row = cursor[1] - 1
    local cursor_col = cursor[2]
    local window_matches = {}

    for _, match in
        ipairs(
            M.matches(
                bufnr,
                { start_row = opts.start_row, end_row = opts.end_row },
                custom_conceal
            )
        )
    do
        if
            conceal_opts.reveal ~= "node"
            or not range_contains(match.reveal, cursor_row, cursor_col)
        then
            window_matches[#window_matches + 1] = match
        end
    end

    return window_matches
end

function M.refresh(bufnr)
    generation = generation + 1
    match_query.reset()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        cache[bufnr] = nil
        shadows.forget(bufnr)
    elseif not bufnr then
        cache = {}
        shadows.reset()
    end
end

function M.forget(bufnr)
    cache[bufnr] = nil
    shadows.forget(bufnr)
end

---Reset conceal match cache and shadow state.
function M.reset()
    generation = 0
    cache = {}
    match_query.reset()
    shadows.reset()
end

function M.generation()
    return generation
end

return M
