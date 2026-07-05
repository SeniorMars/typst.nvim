local config = require("typst.config")
local operation = require("typst.core.operation")
local registry_cache = require("typst.package.registry_cache")
local scan_cache = require("typst.core.scan_cache")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

local info_cache = nil
local info_pending = false
local info_job = nil
local info_failure = nil
local packages_cache = registry_cache.new()
local known_roots_cache = scan_cache.new()
local roots_refresh_pending = false
local schedule_refresh
local KNOWN_ROOTS_KEY = "known-roots"

-- Typst package root discovery.
--
-- The authoritative package paths come from `typst info --format json`, but
-- that command can be slow or temporarily unavailable during completion. Keep
-- the last known roots and merge environment overrides so lookups degrade
-- gracefully.
local function now_ms()
    if type(M._now_ms) == "function" then
        return M._now_ms()
    end
    if uv and type(uv.now) == "function" then
        return uv.now()
    end
    return math.floor(vim.loop.hrtime() / 1000000)
end

local function failure_delay_ms(count)
    if count <= 1 then
        return 1000
    end
    if count == 2 then
        return 5000
    end
    return 30000
end

local function decode_json(text)
    if vim.json and vim.json.decode then
        return vim.json.decode(text)
    end

    return vim.fn.json_decode(text)
end

local function typst_info(opts)
    opts = opts or {}
    if type(info_cache) == "table" then
        return info_cache
    end

    if opts.memory_only == true then
        return nil
    end

    if info_pending then
        return nil
    end

    if info_failure and now_ms() < info_failure.retry_at then
        -- Avoid spawning `typst info` on every completion attempt after a
        -- failure; package roots can fall back to env paths until retry_at.
        return nil
    end

    local executable = config.unsafe_get().executable
    if vim.fn.executable(util.command_executable(executable)) ~= 1 then
        local count = (info_failure and info_failure.count or 0) + 1
        info_failure = {
            count = count,
            retry_at = now_ms() + failure_delay_ms(count),
        }
        return nil
    end

    local command = util.command_prefix(executable)
    vim.list_extend(command, { "info", "--format", "json" })
    info_pending = true
    local job = operation.run("package-info", command, { text = true }, {
        timeout_ms = 1500,
    })
    info_job = job
    job:on_finish(function(result)
        if info_job ~= job then
            return
        end
        info_job = nil
        info_pending = false

        if result and result.code == 0 and result.stdout ~= "" then
            local decoded_ok, decoded = pcall(decode_json, result.stdout)
            if decoded_ok and type(decoded) == "table" then
                info_cache = decoded
                info_failure = nil
                return
            end
        end
        local count = (info_failure and info_failure.count or 0) + 1
        info_failure = {
            count = count,
            retry_at = now_ms() + failure_delay_ms(count),
        }
    end)
    return nil
end

local function env_paths(name)
    local value = vim.env[name]
    if type(value) ~= "string" or value == "" then
        return {}
    end

    local paths = {}
    local separator = util.is_windows() and ";" or ":"
    for path in value:gmatch("([^" .. vim.pesc(separator) .. "]+)") do
        paths[#paths + 1] = path
    end
    return paths
end

local function known_roots_signature()
    return {
        "typst-package-roots",
        tostring(config.generation and config.generation() or 0),
    }
end

function M.package_roots(opts)
    opts = opts or {}
    local ttl_ms = tonumber(opts.ttl_ms)
    if ttl_ms == nil then
        ttl_ms = (config.unsafe_get().completion or {}).package_cache_ttl_ms
            or 5000
    end

    if opts.memory_only == true then
        local cached_roots, fresh =
            scan_cache.peek(known_roots_cache, KNOWN_ROOTS_KEY, {
                signature = known_roots_signature(),
                ttl_ms = ttl_ms,
                now_ms = now_ms(),
            })
        cached_roots = cached_roots or {}
        local stale = opts.force_refresh == true
            or not fresh
            or #cached_roots == 0
        if stale and opts.schedule_refresh ~= false and schedule_refresh then
            schedule_refresh({
                ttl_ms = ttl_ms,
                force_refresh = opts.force_refresh,
            })
        end
        -- The memory-only path is used by completion. It must not block on
        -- `typst info`; stale roots are acceptable because registry_cache will
        -- refresh asynchronously.
        local roots = {}
        vim.list_extend(roots, cached_roots)
        vim.list_extend(roots, env_paths("TYPST_PACKAGE_PATH"))
        vim.list_extend(roots, env_paths("TYPST_PACKAGE_CACHE_PATH"))
        return registry_cache.dedupe(roots)
    end

    local roots = {}
    local info = typst_info()
    local packages = info and info.packages or {}
    roots[#roots + 1] = packages["package-path"]
    roots[#roots + 1] = packages["package-cache-path"]

    vim.list_extend(roots, env_paths("TYPST_PACKAGE_PATH"))
    vim.list_extend(roots, env_paths("TYPST_PACKAGE_CACHE_PATH"))

    local known_roots = registry_cache.dedupe(roots)
    scan_cache.put(known_roots_cache, KNOWN_ROOTS_KEY, known_roots, {
        signature = known_roots_signature(),
        ttl_ms = ttl_ms,
        now_ms = now_ms(),
    })
    return vim.deepcopy(known_roots)
end

schedule_refresh = function(opts)
    opts = opts or {}
    if roots_refresh_pending then
        return
    end

    roots_refresh_pending = true
    vim.schedule(function()
        roots_refresh_pending = false
        local completion_config = config.unsafe_get().completion or {}
        local ttl_ms = opts.ttl_ms or completion_config.package_cache_ttl_ms
        local roots = opts.roots
            or M.package_roots({
                memory_only = true,
                ttl_ms = ttl_ms,
                force_refresh = opts.force_refresh,
                schedule_refresh = false,
            })
        if #roots == 0 then
            roots = M.package_roots({
                ttl_ms = ttl_ms,
                force_refresh = opts.force_refresh,
            })
        end
        pcall(packages_cache.cached_packages, packages_cache, roots, {
            ttl_ms = ttl_ms,
            force_refresh = opts.force_refresh,
            memory_only = true,
            schedule_refresh = true,
            max = math.huge,
        })
    end)
end

function M.cached_packages(opts)
    opts = opts or {}
    local completion_config = config.unsafe_get().completion or {}
    opts = vim.tbl_extend("force", {
        ttl_ms = completion_config.package_cache_ttl_ms,
    }, opts)
    local roots = opts.roots
        or M.package_roots({
            memory_only = opts.memory_only == true,
            ttl_ms = opts.ttl_ms,
            force_refresh = opts.force_refresh,
            schedule_refresh = opts.schedule_refresh,
        })
    local records = packages_cache:cached_packages(roots, opts)
    return records
end

function M.prewarm(opts)
    opts = opts or {}
    local completion_config = config.unsafe_get().completion or {}
    if
        opts.force ~= true
        and completion_config.package_cache_prewarm == false
    then
        return false
    end

    if opts.schedule == false then
        pcall(
            packages_cache.prewarm,
            packages_cache,
            opts.roots or M.package_roots(),
            {
                ttl_ms = opts.ttl_ms or completion_config.package_cache_ttl_ms,
                force_refresh = opts.force_refresh,
            }
        )
    else
        schedule_refresh({
            roots = opts.roots,
            ttl_ms = opts.ttl_ms or completion_config.package_cache_ttl_ms,
            force_refresh = opts.force_refresh,
        })
    end
    return true
end

function M.reset()
    if info_job then
        info_job:cancel({ timeout_ms = 0, kill_timeout_ms = 0 })
        info_job = nil
    end
    info_cache = nil
    info_pending = false
    info_failure = nil
    scan_cache.reset(known_roots_cache)
    roots_refresh_pending = false
    packages_cache:clear()
end

return M
