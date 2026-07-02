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
local parser_registrations = {}

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

local function mark_invalidated(bufnr, entry)
    entry.invalidated_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
end

local function invalidate_chunk_range(bufnr, start_row, end_row)
    local entry = cache[bufnr]
    if not entry then
        return
    end
    mark_invalidated(bufnr, entry)

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
    mark_invalidated(bufnr, entry)

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

    if parser_registrations[bufnr] == parser then
        parser_callbacks[bufnr] = true
        return true
    end

    parser:register_cbs({
        on_changedtree = function(ranges)
            if not vim.api.nvim_buf_is_valid(bufnr) then
                parser_callbacks[bufnr] = nil
                if parser_registrations[bufnr] == parser then
                    parser_registrations[bufnr] = nil
                end
                return
            end
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
            if not vim.api.nvim_buf_is_valid(bufnr) then
                parser_callbacks[bufnr] = nil
                if parser_registrations[bufnr] == parser then
                    parser_registrations[bufnr] = nil
                end
                return
            end
            if old_end_row ~= new_end_row then
                invalidate_from(bufnr, start_row)
            else
                invalidate_chunk_range(bufnr, start_row, start_row)
            end
        end,
        on_detach = function(detached_bufnr)
            local target = detached_bufnr or bufnr
            cache[target] = nil
            parser_callbacks[target] = nil
            if parser_registrations[target] == parser then
                parser_registrations[target] = nil
            end
            shadows.forget(target)
        end,
    })
    parser_callbacks[bufnr] = true
    parser_registrations[bufnr] = parser
    return true
end

local function cache_entry(bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local config_generation = config.generation()
    local parser_tracked = ensure_parser_callbacks(bufnr)
    local entry = cache[bufnr]
    if
        entry
        and entry.generation == generation
        and entry.config_generation == config_generation
    then
        if parser_tracked then
            if
                entry.changedtick ~= changedtick
                and entry.invalidated_changedtick ~= changedtick
            then
                entry.chunks = {}
            end
            entry.changedtick = changedtick
            entry.parser_tracked = true
            return entry
        end
        if entry.changedtick ~= changedtick then
            cache[bufnr] = nil
            shadows.forget(bufnr)
            entry = nil
        else
            return entry
        end
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

---Forget cached matches and active parser callback tracking for one buffer.
---
--- Neovim's parser callback API does not provide an unregister handle. Keep the
--- stable parser registration guard during ordinary cache cleanup so a later
--- lookup does not register duplicate callbacks on the same live parser.
---@param bufnr integer Buffer whose conceal cache should be dropped.
---@param opts? {parser_detached?:boolean}
function M.forget(bufnr, opts)
    opts = opts or {}
    cache[bufnr] = nil
    parser_callbacks[bufnr] = nil
    if opts.parser_detached == true or not vim.api.nvim_buf_is_valid(bufnr) then
        parser_registrations[bufnr] = nil
    end
    shadows.forget(bufnr)
end

---Reset conceal match cache and shadow state.
function M.reset()
    generation = 0
    cache = {}
    parser_callbacks = {}
    -- Do not clear parser_registrations on global reset. Neovim LanguageTree
    -- callback registration is not an unregister API, so keeping the parser
    -- identity table prevents reset/re-enable cycles from stacking duplicate
    -- callbacks. Parser on_detach and invalid-buffer cleanup clear stale entries.
    lookup.reset()
    match_query.reset()
    shadows.reset()
end

function M.generation()
    return generation
end

---Return parser callback tracking entry count for lifecycle tests.
---@return integer count Number of tracked parser callback states.
function M._parser_callback_count()
    return vim.tbl_count(parser_callbacks)
end

---Return stable parser registration count for lifecycle tests.
---@return integer count Number of parser identities with registered callbacks.
function M._parser_registration_count()
    return vim.tbl_count(parser_registrations)
end

return M
