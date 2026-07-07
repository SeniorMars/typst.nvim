local completion_items = require("typst.completion.items")
local completion_match = require("typst.completion.match")
local config = require("typst.config")
local lsp_request = require("typst.core.lsp_request")
local log = require("typst.core.log")
local position = require("typst.core.coordinates")
local resource_manager = require("typst.runtime.resource_manager")
local tinymist = require("typst.integrations.tinymist")

local M = {}
local uv = vim.uv or vim.loop

---@class TypstLspCompletionCacheEntry
---@field cache_generation number
---@field pending boolean
---@field bufnr number
---@field changedtick number
---@field position table
---@field context string
---@field result table?
---@field timer userdata?
---@field waiters table[]?
---@field waiter_keys table?

---@class TypstLspCompletionRequestOpts
---@field bufnr number
---@field pos? number[]
---@field position table
---@field completion_context table
---@field context string
---@field include_tinymist boolean
---@field on_tinymist_results fun(items: table[])?
---@field completion_session string

local cache = {
    entries = {},
    order = {},
    generation = 0,
}

local notify_waiters
local CACHE_LIMIT = 64
local MAX_WAITERS = 16
local DEFAULT_TINYMIST_TIMEOUT_MS = 1000

-- Completion LSP bridge.
--
-- Neovim completion frontends expect a quick synchronous item list. Cache
-- Tinymist responses by buffer tick and cursor position, return cached items
-- immediately, and notify waiters when the async LSP request completes.
local kind_map = {
    [vim.lsp.protocol.CompletionItemKind.Text] = "t",
    [vim.lsp.protocol.CompletionItemKind.Method] = "m",
    [vim.lsp.protocol.CompletionItemKind.Function] = "f",
    [vim.lsp.protocol.CompletionItemKind.Constructor] = "f",
    [vim.lsp.protocol.CompletionItemKind.Field] = "m",
    [vim.lsp.protocol.CompletionItemKind.Variable] = "v",
    [vim.lsp.protocol.CompletionItemKind.Class] = "t",
    [vim.lsp.protocol.CompletionItemKind.Interface] = "t",
    [vim.lsp.protocol.CompletionItemKind.Module] = "m",
    [vim.lsp.protocol.CompletionItemKind.Property] = "m",
    [vim.lsp.protocol.CompletionItemKind.Unit] = "v",
    [vim.lsp.protocol.CompletionItemKind.Value] = "v",
    [vim.lsp.protocol.CompletionItemKind.Enum] = "t",
    [vim.lsp.protocol.CompletionItemKind.Keyword] = "k",
    [vim.lsp.protocol.CompletionItemKind.Snippet] = "s",
    [vim.lsp.protocol.CompletionItemKind.Color] = "v",
    [vim.lsp.protocol.CompletionItemKind.File] = "f",
    [vim.lsp.protocol.CompletionItemKind.Reference] = "r",
    [vim.lsp.protocol.CompletionItemKind.Folder] = "d",
    [vim.lsp.protocol.CompletionItemKind.EnumMember] = "m",
    [vim.lsp.protocol.CompletionItemKind.Constant] = "v",
    [vim.lsp.protocol.CompletionItemKind.Struct] = "t",
    [vim.lsp.protocol.CompletionItemKind.Event] = "v",
    [vim.lsp.protocol.CompletionItemKind.Operator] = "o",
    [vim.lsp.protocol.CompletionItemKind.TypeParameter] = "t",
}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function lsp_item_range(item, kind)
    local edit = type(item) == "table" and item.textEdit or nil
    if type(edit) ~= "table" then
        return nil
    end
    if type(edit[kind]) == "table" then
        return vim.deepcopy(edit[kind])
    end
    if type(edit.range) == "table" then
        return vim.deepcopy(edit.range)
    end
end

local function completion_items_from_lsp(raw, base)
    local raw_items = type(raw) == "table" and (raw.items or raw) or {}
    local items = {}
    local seen = {}

    for _, item in ipairs(raw_items) do
        if type(item) == "table" then
            local word = completion_items.lsp_completion_word(item)
            local label = item.label or word
            local filter_text = item.filterText or label or word
            local semantic_key = table.concat({
                label or "",
                word or "",
                item.sortText or "",
                item.filterText or "",
                vim.inspect(item.textEdit),
                vim.inspect(item.additionalTextEdits),
                vim.inspect(item.command),
            }, "\0")
            if type(word) == "string" and word ~= "" then
                completion_items.add_unique(items, seen, word, function(value)
                    return {
                        word = value,
                        abbr = label,
                        menu = "[Tinymist]",
                        kind = kind_map[item.kind] or "v",
                        info = completion_items.info({
                            item.detail,
                            completion_items.lsp_documentation(
                                item.documentation
                            ),
                        }),
                        user_data = {
                            typst = {
                                kind = "lsp",
                                provider = "tinymist",
                                semantic = true,
                                lsp_item = {
                                    label = item.label,
                                    new_text = value,
                                    text_edit = vim.deepcopy(item.textEdit),
                                    insert_range = lsp_item_range(
                                        item,
                                        "insert"
                                    ),
                                    replace_range = lsp_item_range(
                                        item,
                                        "replace"
                                    ),
                                    snippet = item.insertTextFormat
                                        == vim.lsp.protocol.InsertTextFormat.Snippet,
                                    additional_edits = vim.deepcopy(
                                        item.additionalTextEdits
                                    ),
                                    command = vim.deepcopy(item.command),
                                    sort_text = item.sortText,
                                    filter_text = item.filterText,
                                    data = vim.deepcopy(item.data),
                                    raw = vim.deepcopy(item),
                                },
                            },
                        },
                    }
                end, {
                    base = base,
                    key = semantic_key,
                    trim = false,
                    match = function()
                        return completion_match.any_prefix({
                            filter_text,
                            label,
                            word,
                        }, base)
                    end,
                })
            end
        end
    end

    return items
end

local function client_supports_completion(client, bufnr)
    if type(client.supports_method) ~= "function" then
        return true
    end

    local ok, supported =
        pcall(client.supports_method, client, "textDocument/completion", bufnr)
    if ok then
        return supported
    end

    ok, supported =
        pcall(client.supports_method, client, "textDocument/completion")
    return ok and supported or false
end

local function project_for_buffer(bufnr)
    local ok, project = pcall(require, "typst.project")
    if ok and type(project.get) == "function" then
        return project.get(bufnr)
    end
end

local function valid_entry_token(entry)
    if not entry or not entry.epoch_token then
        return true
    end
    local ok, reason = resource_manager.valid_token(entry.epoch_token)
    if ok then
        return true
    end
    log.add("debug", "ignored stale Tinymist completion request", {
        bufnr = entry.bufnr,
        reason = reason,
    })
    return false, reason
end

local function close_timer(entry)
    if not entry or not entry.timer then
        return
    end
    pcall(function()
        if not entry.timer:is_closing() then
            entry.timer:stop()
            entry.timer:close()
        end
    end)
    entry.timer = nil
end

local function cancel_pending_request(entry)
    if entry and entry.pending then
        lsp_request.cancel(entry.client, entry.request_id)
    end
end

local function cache_completion(key, entry)
    cache.generation = (cache.generation or 0) + 1
    entry.cache_generation = cache.generation
    for i = #cache.order, 1, -1 do
        if cache.order[i].key == key then
            table.remove(cache.order, i)
        end
    end
    cache.order[#cache.order + 1] = {
        key = key,
        generation = entry.cache_generation,
    }
    cache.entries[key] = entry

    while #cache.order > CACHE_LIMIT do
        local stale = table.remove(cache.order, 1)
        local current = cache.entries[stale.key]
        if current and current.cache_generation == stale.generation then
            cancel_pending_request(current)
            notify_waiters(current, {})
            close_timer(current)
            cache.entries[stale.key] = nil
        end
    end
end

local function cache_delete(key)
    close_timer(cache.entries[key])
    cache.entries[key] = nil
    for i = #cache.order, 1, -1 do
        if cache.order[i].key == key then
            table.remove(cache.order, i)
        end
    end
end

local function waiter_key(opts, callback)
    if opts.completion_session then
        return tostring(opts.completion_session)
    end
    return tostring(callback)
end

local function add_waiter(entry, opts, base)
    if type(opts.on_tinymist_results) ~= "function" then
        return
    end

    entry.waiters = entry.waiters or {}
    entry.waiter_keys = entry.waiter_keys or {}
    local key = waiter_key(opts, opts.on_tinymist_results)
    if entry.waiter_keys[key] then
        for _, waiter in ipairs(entry.waiters) do
            if waiter.key == key then
                waiter.base = base
                waiter.callback = opts.on_tinymist_results
                return
            end
        end
    end

    if #entry.waiters >= MAX_WAITERS then
        -- Completion engines may re-query while the same LSP request is in
        -- flight. Bound waiters so a slow server cannot retain unbounded
        -- frontend callbacks.
        local dropped = table.remove(entry.waiters, 1)
        if dropped then
            entry.waiter_keys[dropped.key] = nil
        end
    end

    entry.waiter_keys[key] = true
    entry.waiters[#entry.waiters + 1] = {
        key = key,
        base = base,
        callback = opts.on_tinymist_results,
    }
end

local function call_waiter(waiter, items)
    local ok, err = pcall(waiter.callback, items)
    if not ok then
        log.add("warn", "Tinymist completion callback failed", {
            error = err,
            session = waiter.key,
        })
    end
end

function notify_waiters(entry, items)
    local waiters = entry.waiters or {}
    entry.waiters = {}
    entry.waiter_keys = {}
    for _, waiter in ipairs(waiters) do
        call_waiter(waiter, items or {})
    end
end

local function tinymist_timeout_ms()
    local completion = config.unsafe_get().completion or {}
    local timeout = tonumber(completion.tinymist_timeout_ms)
    if timeout == nil then
        timeout = DEFAULT_TINYMIST_TIMEOUT_MS
    end
    return math.max(timeout, 0)
end

local function start_timeout(key, entry)
    local timeout = tinymist_timeout_ms()
    if timeout <= 0 then
        return
    end

    local timer = uv.new_timer()
    if not timer then
        return
    end
    entry.timer = timer
    timer:start(timeout, 0, function()
        vim.schedule(function()
            local current = cache.entries[key]
            if current ~= entry or not entry.pending then
                close_timer(entry)
                return
            end
            lsp_request.cancel(entry.client, entry.request_id)
            log.add("debug", "Tinymist completion request timed out", {
                bufnr = entry.bufnr,
                timeout_ms = timeout,
            })
            notify_waiters(entry, {})
            cache_delete(key)
        end)
    end)
end

local function lsp_position(opts, client)
    if opts.position then
        return opts.position
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    return position.explicit_position(bufnr, client, opts.pos)
        or position.current_position(bufnr, client)
end

local function tinymist_completion_context(context)
    return context == "markup"
        or context == "math"
        or context == "parameter"
        or context == "named_parameter"
        or context == "parameter_value"
end

--- Request Tinymist completion items for a completion context.
---@param opts TypstLspCompletionRequestOpts Request options and callback hooks.
---@param base string Already-typed completion prefix.
---@param context string Typst syntax context detected at the cursor.
---@return table[] items Cached or immediate Tinymist completion items.
function M.items(opts, base, context)
    if
        opts.include_tinymist == false
        or not tinymist_completion_context(context)
    then
        return {}
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local results = {}

    for _, client in ipairs(tinymist.clients(bufnr)) do
        if
            type(client.request) == "function"
            and client_supports_completion(client, bufnr)
        then
            local params = {
                textDocument = vim.lsp.util.make_text_document_params(bufnr),
                position = lsp_position(
                    vim.tbl_extend("force", opts, { bufnr = bufnr }),
                    client
                ),
                context = opts.completion_context,
            }
            if not params.position then
                return results
            end
            local key = table.concat({
                tostring(bufnr),
                tostring(changedtick),
                tostring(client.id or client.name or "tinymist"),
                tostring(params.position and params.position.line or ""),
                tostring(params.position and params.position.character or ""),
                tostring(context or ""),
            }, "\0")
            local cached = cache.entries[key]
            if cached and not valid_entry_token(cached) then
                cancel_pending_request(cached)
                notify_waiters(cached, {})
                cache_delete(key)
                cached = nil
            end

            if cached and cached.result then
                vim.list_extend(
                    results,
                    completion_items_from_lsp(cached.result, base)
                )
            elseif cached and cached.pending then
                add_waiter(cached, opts, base)
            elseif not cached or not cached.pending then
                local entry = {
                    pending = true,
                    bufnr = bufnr,
                    changedtick = changedtick,
                    position = params.position,
                    context = context,
                    epoch_token = resource_manager.token(
                        project_for_buffer(bufnr),
                        "tinymist:completion"
                    ),
                    waiters = {},
                    waiter_keys = {},
                }
                add_waiter(entry, opts, base)
                cache_completion(key, entry)
                local request_start = lsp_request.start(
                    client,
                    "textDocument/completion",
                    params,
                    function(err, result)
                        vim.schedule(function()
                            local entry = cache.entries[key]
                            if not entry then
                                return
                            end
                            close_timer(entry)

                            if not valid_entry_token(entry) then
                                notify_waiters(entry, {})
                                cache_delete(key)
                                return
                            end

                            if err or not result then
                                notify_waiters(entry, {})
                                cache_delete(key)
                                return
                            end
                            if
                                not vim.api.nvim_buf_is_valid(bufnr)
                                or vim.api.nvim_buf_get_changedtick(bufnr)
                                    ~= changedtick
                            then
                                -- Do not cache completions for text that no
                                -- longer matches the request position.
                                cache_delete(key)
                                return
                            end

                            entry.pending = false
                            entry.result = result
                            local waiters = entry.waiters or {}
                            entry.waiters = {}
                            entry.waiter_keys = {}
                            for _, waiter in ipairs(waiters) do
                                call_waiter(
                                    waiter,
                                    completion_items_from_lsp(
                                        result,
                                        waiter.base
                                    )
                                )
                            end
                        end)
                    end,
                    bufnr
                )
                if not request_start.ok then
                    notify_waiters(entry, {})
                    cache_delete(key)
                else
                    entry.client = client
                    entry.request_id = request_start.request_id
                    start_timeout(key, entry)
                end
            end
        end
    end

    return results
end

function M.reset()
    for _, entry in pairs(cache.entries) do
        cancel_pending_request(entry)
        notify_waiters(entry, {})
        close_timer(entry)
    end
    cache = {
        entries = {},
        order = {},
        generation = 0,
    }
end

return M
