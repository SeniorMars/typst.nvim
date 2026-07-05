local cache = require("typst.core.cache")

local M = {}

--- Create an isolated scan-cache store.
---@return table store Cache store passed to `get`.
function M.new()
    return {
        entries = {},
    }
end

--- Build a deterministic signature from scalar invalidation parts.
---@param parts any[]|table|string|number|boolean|nil Signature input.
---@return string signature Stable signature string.
function M.signature(parts)
    if type(parts) ~= "table" then
        return tostring(parts or "")
    end

    local out = {}
    for index, value in ipairs(parts) do
        out[index] = tostring(value or "")
    end
    return table.concat(out, "\n")
end

local function normalized_opts(opts)
    opts = opts or {}
    return {
        signature = opts.signature ~= nil and M.signature(opts.signature)
            or nil,
        ttl_ms = opts.ttl_ms,
        now_ms = opts.now_ms or cache.now_ms(),
    }
end

--- Store scan data under a key.
---@param store table Cache store from `new()`.
---@param key string Cache entry key.
---@param value any Value to cache.
---@param opts? {signature?:string|table,ttl_ms?:number,now_ms?:number}
---@return any value The original value.
function M.put(store, key, value, opts)
    store.entries = store.entries or {}
    opts = normalized_opts(opts)
    store.entries[key] = cache.entry({
        value = vim.deepcopy(value),
    }, opts)
    return value
end

--- Inspect one scan-cache entry.
---@param store table Cache store from `new()`.
---@param key string Cache entry key.
---@param opts? {signature?:string|table,ttl_ms?:number,now_ms?:number}
---@return any value Cached value or nil.
---@return boolean fresh True when the entry matches signature and TTL.
---@return table|nil entry Raw cache entry.
function M.peek(store, key, opts)
    store.entries = store.entries or {}
    opts = normalized_opts(opts)
    local entry = store.entries[key]
    if type(entry) ~= "table" then
        return nil, false, nil
    end
    local fresh = cache.is_fresh(entry, opts)
    return vim.deepcopy(entry.value), fresh, entry
end

--- Return cached scan data or compute and store a new value.
---@param store table Cache store from `new()`.
---@param key string Cache entry key.
---@param opts? {signature?:string|table,ttl_ms?:number,now_ms?:number}
---@param producer fun():any Function that performs the scan on cache miss.
---@return any value Cached or newly produced value.
---@return boolean cached True when the cached value was reused.
function M.get(store, key, opts, producer)
    local value, fresh = M.peek(store, key, opts)
    if fresh then
        return value, true
    end

    value = producer()
    M.put(store, key, value, opts)
    return value, false
end

--- Clear one scan-cache entry or the whole store.
---@param store table Cache store from `new()`.
---@param key? string Optional entry key to remove.
function M.reset(store, key)
    if type(store) ~= "table" then
        return
    end
    if key then
        store.entries = store.entries or {}
        store.entries[key] = nil
    else
        store.entries = {}
    end
end

return M
