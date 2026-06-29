local config = require("typst.config")
local completion_items = require("typst.completion.items")
local completion_match = require("typst.completion.match")
local cache = require("typst.core.cache")
local scan_cache = require("typst.core.scan_cache")
local package_provider = require("typst.package.cache")
local semver = require("typst.core.semver")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

-- Typst package and template completion.
--
-- Package discovery can touch local package caches and optional Universe index
-- files, so normal completion only enters this path for explicit package-looking
-- input such as "@". Memory-only reads keep completion synchronous while a
-- scheduled refresh warms the cache for the next popup.
local M = {}
local uv = vim.uv or vim.loop

---@class TypstPackageRecord
---@field namespace string
---@field name string
---@field version string
---@field spec string
---@field description string?
---@field entrypoint string?
---@field compiler string?
---@field template table?
---@field is_template boolean
---@field provider string

local universe_cache = {
    store = scan_cache.new(),
    refresh_pending = {},
}

local function now_ms()
    if type(M._now_ms) == "function" then
        return M._now_ms()
    end
    return cache.now_ms()
end

local function package_item(record)
    local kind = record.is_template and "template" or "package"
    local template = record.template or {}
    local provider = record.provider or "package"
    return {
        word = record.spec,
        abbr = record.is_template and ("%s [template]"):format(record.spec)
            or record.spec,
        menu = record.is_template and "[Typst template]" or "[Typst package]",
        kind = "m",
        info = completion_items.info({
            record.description,
            ("Spec: %s"):format(record.spec),
            record.entrypoint and ("Entrypoint: " .. record.entrypoint) or nil,
            record.compiler and ("Compiler: " .. record.compiler) or nil,
            template.path and ("Template path: " .. template.path) or nil,
            template.entrypoint
                    and ("Template entrypoint: " .. template.entrypoint)
                or nil,
            record.source and ("Source: " .. record.source) or nil,
        }),
        user_data = {
            typst = {
                kind = kind,
                provider = provider,
                semantic = false,
                spec = record.spec,
                version = record.version,
            },
        },
    }
end

local function package_matches(record, base)
    if base == "" then
        return true
    end

    local candidates = {
        record.spec,
        ("@%s/%s"):format(record.namespace, record.name),
        ("%s/%s"):format(record.namespace, record.name),
        record.name,
    }

    for _, candidate in ipairs(candidates) do
        if completion_match.prefix(candidate, base) then
            return true
        end
    end

    return false
end

local function decode_json_file(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end

    local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok_decode and type(decoded) == "table" then
        return decoded
    end
end

local function normalize_universe_template(value, is_template)
    if type(value) == "table" then
        return value
    end

    if value == true or is_template == true then
        return {}
    end
end

local function normalize_universe_record(raw, source_path)
    if type(raw) ~= "table" then
        return nil
    end

    raw = type(raw.package) == "table"
            and vim.tbl_extend("force", raw, raw.package)
        or raw

    local parsed = raw.spec and package_provider.parse_spec(raw.spec) or nil
    local namespace = raw.namespace
        or (parsed and parsed.namespace)
        or "preview"
    local name = raw.name or (parsed and parsed.name)
    local version = raw.version
        or raw.latest_version
        or raw.latest
        or (parsed and parsed.version)
    if not namespace or not name or not version then
        return nil
    end

    local template = normalize_universe_template(raw.template, raw.is_template)
    local spec = ("@%s/%s:%s"):format(namespace, name, version)
    return {
        namespace = namespace,
        name = name,
        version = version,
        spec = spec,
        description = raw.description or raw.summary,
        entrypoint = raw.entrypoint,
        compiler = raw.compiler,
        keywords = raw.keywords,
        categories = raw.categories,
        template = template,
        is_template = type(template) == "table",
        provider = "universe",
        source = ("Universe index: %s"):format(
            util.relpath(source_path, vim.fn.getcwd())
        ),
    }
end

local function universe_candidates(decoded)
    if decoded.name or decoded.spec then
        return { decoded }
    end

    if type(decoded.packages) == "table" then
        return decoded.packages
    end

    return decoded
end

local function file_signature(path)
    local stat = path and uv.fs_stat(path) or nil
    if not stat then
        return "missing"
    end
    local mtime = stat.mtime or {}
    return table.concat({
        tostring(stat.size or 0),
        tostring(mtime.sec or 0),
        tostring(mtime.nsec or 0),
    }, ":")
end

local function universe_cache_key(paths, max)
    local parts = { tostring(max) }
    for _, path in ipairs(paths or {}) do
        local resolved = util.resolve_path(path)
        parts[#parts + 1] = ("%s:%s"):format(
            tostring(resolved or path),
            file_signature(resolved)
        )
    end
    return table.concat(parts, "\n")
end

local function refresh_universe_index(paths, max, cache_key, ttl_ms)
    local records = {}
    local seen = {}
    for _, path in ipairs(paths) do
        if #records >= max then
            break
        end

        local resolved = util.resolve_path(path)
        if resolved and vim.fn.filereadable(resolved) == 1 then
            local decoded = decode_json_file(resolved)
            for _, raw in pairs(universe_candidates(decoded or {}) or {}) do
                if #records >= max then
                    break
                end

                local record = normalize_universe_record(raw, resolved)
                if record and not seen[record.spec] then
                    seen[record.spec] = true
                    records[#records + 1] = record
                end
            end
        end
    end

    table.sort(records, function(left, right)
        if left.namespace ~= right.namespace then
            return left.namespace < right.namespace
        end
        if left.name ~= right.name then
            return left.name < right.name
        end
        return semver.less(left.version, right.version)
    end)

    scan_cache.put(universe_cache.store, cache_key, records, {
        ttl_ms = ttl_ms,
        now_ms = now_ms(),
    })
    universe_cache.refresh_pending[cache_key] = nil
    return records
end

local function schedule_universe_refresh(paths, max, cache_key, ttl_ms)
    if universe_cache.refresh_pending[cache_key] then
        return
    end

    universe_cache.refresh_pending[cache_key] = true
    vim.schedule(function()
        local started = telemetry.start()
        local ok = pcall(refresh_universe_index, paths, max, cache_key, ttl_ms)
        telemetry.finish("package.universe_refresh", started, {
            paths = #(paths or {}),
            ok = ok,
        })
        if not ok then
            universe_cache.refresh_pending[cache_key] = nil
        end
    end)
end

local function universe_index_packages(paths, max, opts)
    opts = opts or {}
    if type(paths) ~= "table" or #paths == 0 then
        return {}
    end

    local cache_key = universe_cache_key(paths, max)
    local ttl_ms = tonumber(opts.ttl_ms)
    if ttl_ms == nil then
        ttl_ms = (config.unsafe_get().completion or {}).package_cache_ttl_ms
            or 5000
    end
    local cached, fresh = scan_cache.peek(universe_cache.store, cache_key, {
        ttl_ms = ttl_ms,
        now_ms = now_ms(),
    })
    local stale = cached ~= nil and not fresh
    if opts.memory_only == true then
        -- Completion must not block on JSON index scans. Return whatever is in
        -- memory now and refresh later unless the caller explicitly opted out.
        if (not cached or stale) and opts.schedule_refresh ~= false then
            schedule_universe_refresh(paths, max, cache_key, ttl_ms)
        end
        return cached or {}
    end

    if cached and not stale then
        return cached
    end
    return refresh_universe_index(paths, max, cache_key, ttl_ms)
end

function M.items(opts, base)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_packages == false
        or completion_config.include_packages == false
    then
        return {}
    end

    local should_scan = opts.include_packages == true
        or completion_match.starts_with(base, "@")
    -- Avoid scanning package caches during ordinary identifier completion. Users
    -- can force package results, but the default mirrors Typst syntax where
    -- package specs are introduced with "@".
    if not should_scan then
        return {}
    end

    local include_templates = opts.include_templates ~= false
        and completion_config.include_templates ~= false
    local records = package_provider.cached_packages({
        max = completion_config.package_scan_max,
        memory_only = opts.package_memory_only ~= false,
        prefix = base,
        schedule_refresh = true,
    })
    vim.list_extend(
        records,
        universe_index_packages(
            completion_config.universe_index_paths,
            completion_config.package_scan_max,
            {
                memory_only = opts.package_memory_only ~= false,
                schedule_refresh = true,
                ttl_ms = completion_config.package_cache_ttl_ms,
            }
        )
    )
    local items = {}
    local seen = {}
    for _, record in ipairs(records) do
        if include_templates or not record.is_template then
            completion_items.add_unique(items, seen, record.spec, function()
                return package_item(record)
            end, {
                base = base,
                key = record.spec,
                trim = false,
                match = function()
                    return package_matches(record, base)
                end,
            })
        end
    end

    return items
end

function M.prewarm(opts)
    opts = opts or {}
    local completion_config = config.unsafe_get().completion
    package_provider.prewarm({
        force = opts.force == true,
        force_refresh = opts.force_refresh,
        schedule = opts.schedule,
        ttl_ms = opts.ttl_ms,
    })
    local paths = opts.universe_index_paths
        or completion_config.universe_index_paths
    if type(paths) == "table" and #paths > 0 then
        local cache_key =
            universe_cache_key(paths, completion_config.package_scan_max)
        if opts.schedule == false then
            refresh_universe_index(
                paths,
                completion_config.package_scan_max,
                cache_key,
                opts.ttl_ms or completion_config.package_cache_ttl_ms
            )
        else
            schedule_universe_refresh(
                paths,
                completion_config.package_scan_max,
                cache_key,
                opts.ttl_ms or completion_config.package_cache_ttl_ms
            )
        end
    end
end

function M.reset()
    universe_cache = {
        store = scan_cache.new(),
        refresh_pending = {},
    }
end

return M
