local log = require("typst.core.log")
local async_state = require("typst.core.async_state")
local semantic_items = require("typst.project.semantic_items")
local services = require("typst.project.services")
local tinymist_requests = require("typst.integrations.tinymist.requests")
local tinymist_symbols = require("typst.integrations.tinymist.symbols")
local util = require("typst.core.util")

local M = {}

local DEFAULT_TIMEOUT_MS = 1000

local function semantic_state(project)
    local index = services.index(project)
    if type(index) ~= "table" then
        return nil
    end

    index.semantic = index.semantic or {}
    index.semantic.document = index.semantic.document or {}
    index.semantic.references = index.semantic.references or {}
    index.semantic.workspace = index.semantic.workspace or {}
    return index.semantic, index
end

local function current_tick(bufnr)
    if
        not (
            bufnr
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        )
    then
        return nil
    end

    return vim.api.nvim_buf_get_changedtick(bufnr)
end

local function buffer_path(bufnr)
    if
        not (
            bufnr
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        )
    then
        return nil
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    return name ~= "" and util.normalize(name) or nil
end

local function document_buffers(project)
    local out = {}
    local seen = {}

    local function add(bufnr)
        if
            bufnr
            and bufnr > 0
            and not seen[bufnr]
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        then
            seen[bufnr] = true
            out[#out + 1] = bufnr
        end
    end

    for bufnr in pairs(project.bufs or {}) do
        add(bufnr)
    end
    add(project.main and util.loaded_buffer_for_path(project.main) or nil)
    table.sort(out)
    return out
end

local function request_timeout(opts)
    return opts.tinymist_timeout_ms or opts.timeout_ms or DEFAULT_TIMEOUT_MS
end

local function symbol_file(symbol, fallback_path)
    local file = symbol and (symbol.file or fallback_path) or nil
    return file and util.normalize(file) or nil
end

local function referenceable_symbol(symbol)
    return symbol
        and symbol.name
        and semantic_items.definition_kind(symbol.kind) ~= nil
end

local function reference_context(symbol, fallback_path)
    if not referenceable_symbol(symbol) then
        return nil
    end

    local file = symbol_file(symbol, fallback_path)
    local bufnr = file and util.loaded_buffer_for_path(file) or nil
    local path = bufnr and buffer_path(bufnr) or nil
    if not (file and bufnr and path and util.same_path(file, path)) then
        return nil
    end

    local tick = current_tick(bufnr)
    if not tick then
        return nil
    end

    local row = math.max((tonumber(symbol.lnum) or 1) - 1, 0)
    local col = math.max((tonumber(symbol.col) or 1) - 1, 0)
    return {
        bufnr = bufnr,
        col = col,
        file = file,
        key = ("%s\n%s\n%d\n%d"):format(file, symbol.name, row, col),
        name = symbol.name,
        path = path,
        row = row,
        tick = tick,
    }
end

local function fresh_reference_cache(cache, context, index_generation)
    return cache
        and cache.result
        and cache.index_generation == index_generation
        and cache.changedtick == context.tick
        and cache.path == context.path
        and cache.name == context.name
end

local function schedule_reference_request(
    state,
    symbol,
    fallback_path,
    opts,
    index_generation
)
    local context = reference_context(symbol, fallback_path)
    if not context then
        return nil
    end

    local cache = state.references[context.key] or {}
    state.references[context.key] = cache
    if
        (
            cache.pending
            and cache.pending_index_generation == index_generation
            and cache.pending_changedtick == context.tick
            and cache.pending_path == context.path
            and cache.pending_name == context.name
        )
        or fresh_reference_cache(cache, context, index_generation)
    then
        return cache
    end

    local generation = (cache.generation or 0) + 1
    cache.generation = generation
    cache.pending = true
    cache.pending_index_generation = index_generation
    cache.pending_changedtick = context.tick
    cache.pending_name = context.name
    cache.pending_path = context.path

    vim.schedule(function()
        if
            current_tick(context.bufnr) ~= context.tick
            or buffer_path(context.bufnr) ~= context.path
        then
            async_state.clear_pending(cache)
            return
        end

        async_state.start_pending(cache, {
            "pending_index_generation",
            "pending_changedtick",
            "pending_name",
            "pending_path",
        }, function()
            return tinymist_requests.references(context.bufnr, {
                callback = function(reference_result)
                    if cache.generation ~= generation then
                        return
                    end

                    cache.pending = false
                    cache.pending_index_generation = nil
                    cache.pending_changedtick = nil
                    cache.pending_name = nil
                    cache.pending_path = nil
                    cache.index_generation = index_generation
                    cache.changedtick = context.tick
                    cache.name = context.name
                    cache.path = context.path
                    if
                        type(reference_result) == "table"
                        and reference_result.ok
                    then
                        cache.result = reference_result
                        cache.error = nil
                    else
                        cache.result = nil
                        cache.error = reference_result
                        if
                            reference_result
                            and reference_result.reason ~= "no_client"
                        then
                            log.add("debug", "Tinymist references failed", {
                                name = context.name,
                                reason = reference_result.reason,
                                message = reference_result.message,
                            })
                        end
                    end
                end,
                guard_changedtick = true,
                guard_cursor = false,
                include_declaration = false,
                pos = { context.row, context.col },
                timeout_ms = request_timeout(opts),
            })
        end)
    end)
    return cache
end

local function schedule_symbol_references(
    state,
    symbols,
    fallback_path,
    opts,
    index_generation
)
    for _, symbol in ipairs(symbols or {}) do
        schedule_reference_request(
            state,
            symbol,
            fallback_path,
            opts,
            index_generation
        )
    end
end

local function merge_reference_cache(
    out,
    seen,
    symbol,
    fallback_path,
    state,
    opts,
    index_generation
)
    local cache = schedule_reference_request(
        state,
        symbol,
        fallback_path,
        opts,
        index_generation
    )
    local context = reference_context(symbol, fallback_path)
    if
        not (
            context
            and fresh_reference_cache(cache, context, index_generation)
        )
    then
        return
    end

    if type(cache) ~= "table" then
        return
    end

    local result = cache.result
    if type(result) ~= "table" then
        return
    end

    for _, location in ipairs(result.references or {}) do
        semantic_items.add_reference(out, seen, context.name, location)
    end
end

local function schedule_document_request(project, bufnr, opts)
    local state, index = semantic_state(project)
    if not state then
        return
    end

    local tick = current_tick(bufnr)
    local path = buffer_path(bufnr)
    if not tick or not path then
        return
    end

    local cache = state.document[bufnr] or {}
    state.document[bufnr] = cache
    if
        (
            cache.pending
            and cache.pending_changedtick == tick
            and cache.pending_path == path
        )
        or (cache.result and cache.changedtick == tick and cache.path == path)
    then
        return
    end

    local generation = (cache.generation or 0) + 1
    cache.generation = generation
    cache.pending = true
    cache.pending_changedtick = tick
    cache.pending_path = path

    vim.schedule(function()
        if current_tick(bufnr) ~= tick or buffer_path(bufnr) ~= path then
            async_state.clear_pending(cache, {
                "pending_changedtick",
                "pending_path",
            })
            return
        end

        async_state.start_pending(cache, {
            "pending_changedtick",
            "pending_path",
        }, function()
            return tinymist_symbols.document_symbols(bufnr, {
                timeout_ms = request_timeout(opts),
                guard_cursor = false,
                guard_changedtick = true,
                callback = function(result)
                    if cache.generation ~= generation then
                        return
                    end

                    cache.pending = false
                    cache.pending_changedtick = nil
                    cache.pending_path = nil
                    cache.changedtick = tick
                    cache.path = path
                    if type(result) == "table" and result.ok then
                        cache.result = result
                        cache.error = nil
                        schedule_symbol_references(
                            state,
                            result.symbols,
                            path,
                            opts,
                            index and index.generation or 0
                        )
                    else
                        cache.result = nil
                        cache.error = result
                        if result and result.reason ~= "no_client" then
                            log.add(
                                "debug",
                                "Tinymist document symbols failed",
                                {
                                    reason = result.reason,
                                    message = result.message,
                                }
                            )
                        end
                    end
                end,
            })
        end)
    end)
end

local function schedule_workspace_request(project, opts, index)
    local state = semantic_state(project)
    if not state then
        return
    end

    local cache = state.workspace
    local generation = index and index.generation or 0
    local query = opts.tinymist_workspace_query or opts.workspace_query or ""
    if
        (
            cache.pending
            and cache.pending_index_generation == generation
            and cache.pending_query == query
        )
        or (
            cache.result
            and cache.index_generation == generation
            and cache.query == query
        )
    then
        return
    end

    local request_generation = (cache.generation or 0) + 1
    cache.generation = request_generation
    cache.pending = true
    cache.pending_index_generation = generation
    cache.pending_query = query

    vim.schedule(function()
        async_state.start_pending(cache, {
            "pending_index_generation",
            "pending_query",
        }, function()
            return tinymist_symbols.workspace_symbols(project, {
                query = query,
                timeout_ms = request_timeout(opts),
                guard_cursor = false,
                guard_changedtick = false,
                callback = function(result)
                    if cache.generation ~= request_generation then
                        return
                    end

                    cache.pending = false
                    cache.pending_index_generation = nil
                    cache.pending_query = nil
                    cache.index_generation = generation
                    cache.query = query
                    if type(result) == "table" and result.ok then
                        cache.result = result
                        cache.error = nil
                        schedule_symbol_references(
                            state,
                            result.symbols,
                            project.main,
                            opts,
                            generation
                        )
                    else
                        cache.result = nil
                        cache.error = result
                        if result and result.reason ~= "no_client" then
                            log.add(
                                "debug",
                                "Tinymist workspace symbols failed",
                                {
                                    reason = result.reason,
                                    message = result.message,
                                }
                            )
                        end
                    end
                end,
            })
        end)
    end)
end

local function merge_symbols(out, seen, symbols, fallback_path, helpers)
    for _, symbol in ipairs(symbols or {}) do
        semantic_items.add_symbol(out, seen, symbol, fallback_path, helpers)
    end
end

local function merge_references(
    out,
    seen,
    state,
    symbols,
    fallback_path,
    opts,
    index_generation
)
    for _, symbol in ipairs(symbols or {}) do
        merge_reference_cache(
            out,
            seen,
            symbol,
            fallback_path,
            state,
            opts,
            index_generation
        )
    end
end

function M.merge_document_symbols(project, out, seen, opts, helpers)
    if opts.include_tinymist ~= true then
        return
    end

    local state, index = semantic_state(project)
    if not state then
        return
    end
    local generation = index and index.generation or 0

    for _, bufnr in ipairs(document_buffers(project)) do
        schedule_document_request(project, bufnr, opts)
        local cache = state.document[bufnr]
        if
            cache
            and cache.result
            and cache.changedtick == current_tick(bufnr)
            and cache.path == buffer_path(bufnr)
        then
            merge_symbols(
                out,
                seen,
                cache.result.symbols,
                cache.path or project.main,
                helpers
            )
            merge_references(
                out,
                seen,
                state,
                cache.result.symbols,
                cache.path or project.main,
                opts,
                generation
            )
        end
    end
end

function M.merge_workspace_symbols(project, out, seen, opts, traversal, helpers)
    if opts.include_tinymist ~= true then
        return
    end

    local state, index = semantic_state(project)
    if not state then
        return
    end

    schedule_workspace_request(project, opts, index)
    local cache = state.workspace
    local generation = index and index.generation or 0
    local query = opts.tinymist_workspace_query or opts.workspace_query or ""
    if
        cache
        and cache.result
        and cache.index_generation == generation
        and cache.query == query
    then
        merge_symbols(out, seen, cache.result.symbols, project.main, helpers)
        merge_references(
            out,
            seen,
            state,
            cache.result.symbols,
            project.main,
            opts,
            generation
        )
    end
end

return M
