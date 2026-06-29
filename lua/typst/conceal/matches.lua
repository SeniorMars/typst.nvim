local config = require("typst.config")
local lookup = require("typst.conceal.lookup")
local match_query = require("typst.conceal.match_query")
local reveal = require("typst.conceal.reveal")
local shadows = require("typst.conceal.shadows")
local telemetry = require("typst.core.telemetry")

local M = {}

local cache = {}
local generation = 0
local MATCH_CHUNK_LINES = 128
local parser_callbacks = {}

-- Conceal queries are expensive on large documents. Parser-backed buffers use
-- changed-tree callbacks to invalidate affected line chunks; buffers without a
-- parser callback fall back to changedtick-based full cache refresh.
local function line_count(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
end

local function conceal_config()
    return config.unsafe_get().conceal
end

local function range_start_row(range)
    if type(range) ~= "table" then
        return nil
    end
    return range.start_row or range[1]
end

local function range_end_row(range)
    if type(range) ~= "table" then
        return nil
    end
    if range.end_row then
        return range.end_row
    end
    -- LanguageTree:on_changedtree passes node ranges:
    -- {start_row, start_col, start_byte, end_row, end_col, end_byte}.
    if #range >= 6 then
        return range[4]
    end
    return range[3] or range_start_row(range)
end

local function chunk_key(chunk_start, chunk_end)
    return ("%d:%d"):format(chunk_start, chunk_end)
end

local function chunk_start_for(row)
    return math.floor(math.max(row, 0) / MATCH_CHUNK_LINES) * MATCH_CHUNK_LINES
end

local function invalidate_chunk_range(bufnr, start_row, end_row)
    local entry = cache[bufnr]
    if not entry then
        return
    end

    start_row = math.max(0, tonumber(start_row) or 0)
    end_row = tonumber(end_row) or start_row
    if end_row < start_row then
        end_row = start_row
    end

    local first_chunk = chunk_start_for(math.max(0, start_row - 1))
    local last_chunk = chunk_start_for(math.max(first_chunk, end_row + 1))
    local total = line_count(bufnr)
    local chunk_start = first_chunk
    while chunk_start <= last_chunk do
        local chunk_end = math.min(total, chunk_start + MATCH_CHUNK_LINES)
        entry.chunks[chunk_key(chunk_start, chunk_end)] = nil
        chunk_start = chunk_start + MATCH_CHUNK_LINES
    end
end

local function invalidate_from(bufnr, start_row)
    local entry = cache[bufnr]
    if not entry then
        return
    end

    local total = line_count(bufnr)
    local chunk_start = chunk_start_for(start_row or 0)
    while chunk_start <= total do
        local chunk_end = math.min(total, chunk_start + MATCH_CHUNK_LINES)
        entry.chunks[chunk_key(chunk_start, chunk_end)] = nil
        chunk_start = chunk_start + MATCH_CHUNK_LINES
    end
end

function M.invalidate_ranges(bufnr, ranges)
    if not cache[bufnr] then
        return false
    end

    local invalidated = false
    for _, range in ipairs(ranges or {}) do
        local start_row = range_start_row(range)
        local end_row = range_end_row(range)
        if start_row then
            invalidate_chunk_range(bufnr, start_row, end_row or start_row)
            invalidated = true
        end
    end
    return invalidated
end

local function ensure_parser_callbacks(bufnr)
    if parser_callbacks[bufnr] ~= nil then
        return parser_callbacks[bufnr]
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    if not ok or not parser or type(parser.register_cbs) ~= "function" then
        parser_callbacks[bufnr] = false
        return false
    end

    parser:register_cbs({
        on_changedtree = function(ranges)
            M.invalidate_ranges(bufnr, ranges)
        end,
        on_bytes = function(
            _,
            _,
            start_row,
            _,
            _,
            old_end_row,
            _,
            _,
            new_end_row
        )
            if old_end_row ~= new_end_row then
                invalidate_from(bufnr, start_row)
            end
        end,
        on_detach = function(detached_bufnr)
            local target = detached_bufnr or bufnr
            cache[target] = nil
            parser_callbacks[target] = nil
            shadows.forget(target)
        end,
    })
    parser_callbacks[bufnr] = true
    return true
end

local function cache_entry(bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local config_generation = config.generation()
    local parser_tracked = ensure_parser_callbacks(bufnr)
    local entry = cache[bufnr]
    if
        entry
        and (parser_tracked or entry.changedtick == changedtick)
        and entry.generation == generation
        and entry.config_generation == config_generation
    then
        entry.changedtick = changedtick
        return entry
    end

    entry = {
        changedtick = changedtick,
        parser_tracked = parser_tracked,
        generation = generation,
        config_generation = config_generation,
        chunks = {},
    }
    cache[bufnr] = entry

    return entry
end

local function chunk_matches(bufnr, entry, chunk_start, custom_conceal)
    local total = line_count(bufnr)
    local chunk_end = math.min(total, chunk_start + MATCH_CHUNK_LINES)
    local key = chunk_key(chunk_start, chunk_end)
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
    return reveal.filter(
        M.matches(
            bufnr,
            { start_row = opts.start_row, end_row = opts.end_row },
            custom_conceal
        ),
        conceal_opts,
        cursor_row,
        cursor_col
    )
end

function M.refresh(bufnr)
    generation = generation + 1
    lookup.reset()
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
    lookup.reset()
    match_query.reset()
    shadows.reset()
end

function M.generation()
    return generation
end

return M
