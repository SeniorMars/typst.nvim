local registry_scan = require("typst.package.registry_scan")
local semver = require("typst.core.semver")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local schedule_refresh
local PACKAGE_WATCH_DEBOUNCE_MS = 100

---@class TypstPackageCacheEntry
---@field signatures table<string,string|number>|nil
---@field records table[]|nil
---@field by_name table<string, table[]>|nil
---@field prefix_candidates table[]|nil
---@field expires_at number|nil
---@field refresh_pending boolean|nil

-- In-memory package index with stale-while-refresh behavior.
--
-- Package completion must stay responsive even when the package cache is large
-- or filesystem watchers fire repeatedly. Callers can take current records
-- immediately while an async scan refreshes signatures in the background.
local function now_ms()
    if type(M._now_ms) == "function" then
        return M._now_ms()
    end
    if uv and type(uv.now) == "function" then
        return uv.now()
    end
    return math.floor(vim.loop.hrtime() / 1000000)
end

local function copy_record(record)
    return vim.deepcopy(record)
end

local function copy_records(values)
    local copy = {}
    for index, value in ipairs(values or {}) do
        copy[index] = copy_record(value)
    end
    return copy
end

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

function M.dedupe(paths)
    local seen = {}
    local result = {}
    for _, path in ipairs(paths or {}) do
        path = trim(path)
        if path then
            path = util.normalize(path)
            if not seen[path] then
                seen[path] = true
                result[#result + 1] = path
            end
        end
    end
    return result
end

local function close_watcher(record)
    local handle = record and record.handle
    if not handle then
        return
    end

    pcall(function()
        if not handle:is_closing() then
            handle:stop()
            handle:close()
        end
    end)
end

local function close_watchers(cache, cache_key)
    local watchers = cache.watchers and cache.watchers[cache_key]
    if not watchers then
        return
    end

    for key, record in pairs(watchers) do
        close_watcher(record)
        watchers[key] = nil
    end
    cache.watchers[cache_key] = nil
end

local function schedule_changed_refresh(cache, cache_key, roots, ttl_ms)
    if cache.watch_pending[cache_key] then
        return
    end

    -- Filesystem package managers often write several files per install. Debounce
    -- watcher invalidation so one package update schedules one refresh.
    cache.watch_pending[cache_key] = true
    vim.defer_fn(function()
        cache.watch_pending[cache_key] = nil
        local cached = cache.entries[cache_key]
        if cached then
            cached.expires_at = 0
            cached.signatures =
                vim.tbl_extend("force", cached.signatures or {}, {
                    fs_event_at = tostring(now_ms()),
                })
        end
        schedule_refresh(cache, cache_key, roots, ttl_ms, true)
    end, PACKAGE_WATCH_DEBOUNCE_MS)
end

local function start_watcher(cache, cache_key, roots, ttl_ms, dir)
    if not (uv and type(uv.new_fs_event) == "function") then
        return nil
    end

    local handle = uv.new_fs_event()
    local started = pcall(function()
        handle:start(dir, {}, function(err)
            if err then
                return
            end
            vim.schedule(function()
                local watchers = cache.watchers and cache.watchers[cache_key]
                local record = watchers and watchers[util.path_key(dir)]
                if record and record.handle == handle then
                    schedule_changed_refresh(cache, cache_key, roots, ttl_ms)
                end
            end)
        end)
    end)

    if not started then
        close_watcher({ handle = handle })
        return nil
    end

    return {
        handle = handle,
        path = dir,
    }
end

local function sync_watchers(cache, cache_key, roots, ttl_ms)
    if cache.watch_roots == false then
        return
    end

    local wanted = {}
    for _, dir in ipairs(registry_scan.watch_dirs(roots)) do
        wanted[util.path_key(dir)] = dir
    end

    cache.watchers[cache_key] = cache.watchers[cache_key] or {}
    local watchers = cache.watchers[cache_key]

    for key, record in pairs(watchers) do
        if wanted[key] ~= record.path then
            close_watcher(record)
            watchers[key] = nil
        end
    end

    for key, dir in pairs(wanted) do
        if not watchers[key] then
            watchers[key] = start_watcher(cache, cache_key, roots, ttl_ms, dir)
        end
    end
end

local function same_signatures(left, right)
    left = left or {}
    right = right or {}

    for root, signature in pairs(left) do
        if right[root] ~= signature then
            return false
        end
    end

    for root, signature in pairs(right) do
        if left[root] ~= signature then
            return false
        end
    end

    return true
end

local function add_prefix_candidate(candidates, key, record, order)
    key = trim(key)
    if key then
        candidates[#candidates + 1] = {
            key = key:lower(),
            record = record,
            order = order,
        }
    end
end

local function package_cache_entry(records, signatures)
    local cached_records = {}
    local by_name = {}
    local prefix_candidates = {}

    local function add_named(key, record)
        by_name[key] = by_name[key] or {}
        by_name[key][#by_name[key] + 1] = record
    end

    for index, record in ipairs(records) do
        cached_records[index] = record
        add_named(("%s/%s"):format(record.namespace, record.name), record)
        add_named(record.name, record)
        add_prefix_candidate(prefix_candidates, record.spec, record, index)
        add_prefix_candidate(
            prefix_candidates,
            ("@%s/%s"):format(record.namespace, record.name),
            record,
            index
        )
        add_prefix_candidate(
            prefix_candidates,
            ("%s/%s"):format(record.namespace, record.name),
            record,
            index
        )
        add_prefix_candidate(prefix_candidates, record.name, record, index)
    end

    table.sort(prefix_candidates, function(left, right)
        if left.key == right.key then
            return left.record.spec < right.record.spec
        end
        return left.key < right.key
    end)

    return {
        signatures = signatures,
        records = cached_records,
        by_name = by_name,
        prefix_candidates = prefix_candidates,
        expires_at = nil,
    }
end

local function lower_bound(candidates, prefix)
    local low = 1
    local high = #candidates + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        if candidates[mid].key < prefix then
            low = mid + 1
        else
            high = mid
        end
    end
    return low
end

local function limit_records(records, max)
    if type(max) ~= "number" then
        return records
    end

    local limited = {}
    for index = 1, math.min(max, #records) do
        limited[index] = records[index]
    end
    return limited
end

local function filter_by_prefix(entry, prefix, max)
    prefix = trim(prefix)
    if not prefix then
        return limit_records(copy_records(entry.records), max)
    end

    prefix = prefix:lower()
    local matches = {}
    local seen = {}
    local candidates = entry.prefix_candidates or {}
    local index = lower_bound(candidates, prefix)
    while index <= #candidates do
        local candidate = candidates[index]
        if candidate.key:sub(1, #prefix) ~= prefix then
            break
        end
        if not seen[candidate.record.spec] then
            seen[candidate.record.spec] = true
            matches[#matches + 1] = candidate
        end
        index = index + 1
    end

    table.sort(matches, function(left, right)
        return left.order < right.order
    end)

    local records = {}
    for _, match in ipairs(matches) do
        records[#records + 1] = match.record
    end
    return limit_records(copy_records(records), max)
end

local function records_from_entry(entry, opts, max)
    if opts.namespace and opts.name then
        return limit_records(
            copy_records(
                entry.by_name[("%s/%s"):format(opts.namespace, opts.name)] or {}
            ),
            max
        )
    end
    if opts.name then
        return limit_records(copy_records(entry.by_name[opts.name] or {}), max)
    end
    return filter_by_prefix(entry, opts.prefix, max)
end

local function sort_records(records)
    table.sort(records, function(left, right)
        if left.namespace ~= right.namespace then
            return left.namespace < right.namespace
        end
        if left.name ~= right.name then
            return left.name < right.name
        end
        return semver.less(left.version, right.version)
    end)
    return records
end

local function refresh_entry(cache, cache_key, roots, opts)
    local signatures = registry_scan.root_signatures(roots)
    local cached = cache.entries[cache_key]
    if
        not cached
        or opts.force_refresh
        or not same_signatures(cached.signatures, signatures)
    then
        local records = registry_scan.scan_roots(roots)
        sort_records(records)

        cached = package_cache_entry(records, signatures)
        cache.entries[cache_key] = cached
    end
    cached.expires_at = opts.ttl_ms > 0 and (now_ms() + opts.ttl_ms) or nil
    cached.refresh_pending = false
    sync_watchers(cache, cache_key, roots, opts.ttl_ms)
    return cached
end

local function async_signatures(roots)
    local signatures = {
        async_refreshed_at = tostring(now_ms()),
    }
    for index, root in ipairs(roots or {}) do
        signatures[("root:%d"):format(index)] = root
    end
    return signatures
end

schedule_refresh = function(cache, cache_key, roots, ttl_ms, force_refresh)
    local started = telemetry.start()
    local cached = cache.entries[cache_key]
    if cached and cached.refresh_pending then
        return
    end
    if cached then
        cached.refresh_pending = true
    else
        cache.entries[cache_key] = {
            signatures = {},
            records = {},
            by_name = {},
            prefix_candidates = {},
            refresh_pending = true,
        }
    end

    registry_scan.scan_roots_async(roots, {
        budget = 64,
    }, function(records, err)
        telemetry.finish("package.refresh", started, {
            roots = #(roots or {}),
            records = type(records) == "table" and #records or 0,
            ok = not err and type(records) == "table",
        })
        local current = cache.entries[cache_key]
        if err or type(records) ~= "table" then
            if current then
                current.refresh_pending = false
            end
            return
        end

        sort_records(records)
        local refreshed = package_cache_entry(records, async_signatures(roots))
        refreshed.expires_at = ttl_ms > 0 and (now_ms() + ttl_ms) or nil
        refreshed.refresh_pending = false
        cache.entries[cache_key] = refreshed
        sync_watchers(cache, cache_key, roots, ttl_ms)
    end)
end

local Cache = {}
Cache.__index = Cache

---@class TypstPackageCache
---@field entries table<string, TypstPackageCacheEntry>
---@field watchers table<string, table>
---@field watch_pending table<string, boolean>

function M.new()
    return setmetatable({
        entries = {},
        watchers = {},
        watch_pending = {},
    }, Cache)
end

--- Clear cached package records and close active registry watchers.
function Cache:clear()
    for cache_key in pairs(self.watchers or {}) do
        close_watchers(self, cache_key)
    end
    self.entries = {}
    self.watchers = {}
    self.watch_pending = {}
end

--- Return package records for registry roots, refreshing synchronously or lazily.
---@param roots string[] Registry roots to scan or read from cache.
---@param opts {max?:number,ttl_ms?:number,memory_only?:boolean,force_refresh?:boolean,schedule_refresh?:boolean,namespace?:string,name?:string,prefix?:string} Cache and filtering controls for the package lookup.
---@return table[] records Package records matching the requested filters.
function Cache:cached_packages(roots, opts)
    opts = opts or {}
    roots = M.dedupe(roots)
    local max = opts.max or 500
    local ttl_ms = tonumber(opts.ttl_ms)
    if ttl_ms == nil then
        ttl_ms = 5000
    end
    local cache_key = table.concat(roots, "\n")
    local cached = self.entries[cache_key]
    local now = now_ms()

    if opts.memory_only == true then
        if cached then
            if
                not opts.force_refresh
                and ttl_ms > 0
                and cached.expires_at
                and cached.expires_at <= now
                and opts.schedule_refresh ~= false
            then
                schedule_refresh(self, cache_key, roots, ttl_ms, false)
            elseif
                not opts.force_refresh
                and opts.schedule_refresh ~= false
                and not cached.refresh_pending
                and not cached.expires_at
                and #(cached.records or {}) == 0
            then
                schedule_refresh(self, cache_key, roots, ttl_ms, false)
            elseif opts.force_refresh and opts.schedule_refresh ~= false then
                schedule_refresh(self, cache_key, roots, ttl_ms, true)
            end
            -- Memory-only callers are latency-sensitive completions. Return
            -- possibly stale package records now and let the scheduled refresh
            -- repair the cache for the next invocation.
            return records_from_entry(cached, opts, max)
        end

        if opts.schedule_refresh ~= false and #roots > 0 then
            schedule_refresh(self, cache_key, roots, ttl_ms, opts.force_refresh)
        end
        return {}
    end

    if
        cached
        and not opts.force_refresh
        and ttl_ms > 0
        and cached.expires_at
        and cached.expires_at > now
    then
        return records_from_entry(cached, opts, max)
    end

    if
        cached
        and not opts.force_refresh
        and ttl_ms > 0
        and cached.expires_at
        and cached.expires_at <= now
    then
        schedule_refresh(self, cache_key, roots, ttl_ms, false)
        return records_from_entry(cached, opts, max)
    end

    cached = refresh_entry(self, cache_key, roots, {
        ttl_ms = ttl_ms,
        force_refresh = opts.force_refresh,
    })
    return records_from_entry(cached, opts, max)
end

--- Warm package registry data for later completion or lookup calls.
---@param roots string[] Registry roots to pre-scan.
---@param opts? table Cache options forwarded to `cached_packages`.
---@return table[] records Cached package records collected during prewarm.
function Cache:prewarm(roots, opts)
    opts = vim.tbl_extend("force", opts or {}, {
        max = opts and opts.max or math.huge,
        prefix = opts and opts.prefix or nil,
    })
    return self:cached_packages(roots, opts)
end

return M
