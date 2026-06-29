local artifacts = require("typst.workflows.artifacts")
local config = require("typst.config")
local preview_service = require("typst.project.services.preview")
local util = require("typst.core.util")

local M = {}

local function cache_config()
    return (config.unsafe_get().preview or {}).cache or {}
end

local function path_key(path)
    return util.path_key(util.canonical(path))
end

local function path_set(paths)
    local set = {}
    for _, path in ipairs(paths or {}) do
        if type(path) == "string" and path ~= "" then
            set[path_key(path)] = true
        end
    end
    return set
end

local function active_paths(project, extra)
    local paths = {}
    local seen = {}
    local function add(path)
        if type(path) ~= "string" or path == "" then
            return
        end
        local canonical = path_key(path)
        if seen[canonical] then
            return
        end
        seen[canonical] = true
        paths[#paths + 1] = path
    end

    local preview = preview_service.get(project) or {}
    add(preview.active_output)
    local native =
        require("typst.preview.native.session").project_state(project)
    if native.active then
        add(native.output)
    end
    for _, path in ipairs(extra or {}) do
        add(path)
    end
    return paths
end

local function entry_time(item, stat)
    local mtime = stat and stat.mtime or {}
    return item.used_at
        or item.created_at
        or (mtime.sec and tonumber(mtime.sec))
        or 0
end

local function preview_entries(project)
    local entries = {}
    for _, item in
        ipairs(artifacts.artifacts(project, { producer = "preview" }))
    do
        local stat = item.path and vim.uv.fs_stat(item.path) or nil
        entries[#entries + 1] = {
            item = item,
            path = item.path,
            key = item.path and path_key(item.path) or nil,
            exists = stat ~= nil,
            bytes = stat and stat.size or 0,
            used_at = entry_time(item, stat),
            created_at = item.created_at,
            preview_export = item.preview_export,
        }
    end
    table.sort(entries, function(left, right)
        if left.used_at == right.used_at then
            return (left.path or "") < (right.path or "")
        end
        return left.used_at > right.used_at
    end)
    return entries
end

local function paths_from_records(records)
    local paths = {}
    for _, record in ipairs(records or {}) do
        paths[#paths + 1] = type(record) == "table" and record.path or record
    end
    return paths
end

function M.retention_candidates(project, opts)
    opts = opts or {}
    local limits = opts.limits or cache_config()
    if limits.enabled == false then
        return {}
    end

    local keep = path_set(active_paths(project, opts.keep_paths))
    local candidates = preview_entries(project)
    local delete = {}
    local delete_seen = {}
    local now = os.time()
    local kept_entries = 0
    local kept_bytes = 0
    for _, entry in ipairs(candidates) do
        if keep[entry.key] and entry.exists then
            kept_entries = kept_entries + 1
            kept_bytes = kept_bytes + entry.bytes
        end
    end

    local function mark(entry, reason)
        if
            not entry.path
            or keep[entry.key]
            or delete_seen[entry.key]
            or not entry.exists
        then
            return
        end
        delete_seen[entry.key] = true
        delete[#delete + 1] = {
            path = entry.path,
            reason = reason,
        }
    end

    local ttl_ms = limits.ttl_ms or 0
    if ttl_ms > 0 then
        local ttl_sec = ttl_ms / 1000
        for _, entry in ipairs(candidates) do
            if entry.used_at > 0 and now - entry.used_at > ttl_sec then
                mark(entry, "ttl")
            end
        end
    end

    local max_entries = limits.max_entries or 0
    if max_entries > 0 then
        local kept = kept_entries
        for _, entry in ipairs(candidates) do
            if not keep[entry.key] and entry.exists then
                kept = kept + 1
                if kept > max_entries then
                    mark(entry, "max_entries")
                end
            end
        end
    end

    local max_bytes = limits.max_bytes or 0
    if max_bytes > 0 then
        local used = kept_bytes
        for _, entry in ipairs(candidates) do
            if not keep[entry.key] and entry.exists then
                used = used + entry.bytes
                if used > max_bytes then
                    mark(entry, "max_bytes")
                end
            end
        end
    end

    return delete
end

function M.prune(project, opts, notify)
    opts = opts or {}
    local stale = M.retention_candidates(project, opts)
    if #stale == 0 then
        return {
            ok = true,
            deleted = {},
            failed = {},
            skipped = {},
            retention = {},
            count = 0,
        }
    end

    local result = artifacts.clean(project, {
        producer = "preview",
        paths = paths_from_records(stale),
        keep_paths = active_paths(project, opts.keep_paths),
        force = opts.force,
    }, notify)
    result.retention = stale
    return result
end

function M.clean(project, opts, notify)
    opts = opts or {}
    if opts.retention == true then
        return M.prune(project, opts, notify)
    end
    return artifacts.clean(project, {
        producer = "preview",
        format = opts.format,
        force = opts.force,
        keep_paths = opts.include_active and {} or active_paths(project),
    }, notify)
end

function M.status(project)
    local entries = preview_entries(project)
    local active = path_set(active_paths(project))
    local total_bytes = 0
    local existing = 0
    for _, entry in ipairs(entries) do
        if entry.exists then
            existing = existing + 1
            total_bytes = total_bytes + entry.bytes
        end
        entry.active = entry.key and active[entry.key] == true or false
    end
    return {
        ok = true,
        limits = vim.deepcopy(cache_config()),
        entries = entries,
        count = #entries,
        existing = existing,
        bytes = total_bytes,
        active_paths = active_paths(project),
    }
end

return M
