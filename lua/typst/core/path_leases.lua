local path_util = require("typst.core.path")

local M = {}

-- In-process lease table for generated output paths.
--
-- Compile, watch, render, and export can all target the same PDF/SVG path. A
-- lease prevents concurrent jobs from trampling one another before the external
-- tool has a chance to write anything.

local leases = {}
local next_id = 0

local function key_for(path)
    return path_util.path_key(path_util.canonical(path))
end

local function lease_error(path, existing)
    return {
        ok = false,
        reason = "active_output",
        message = "Output path is already being written",
        path = path,
        active_output = existing and existing.path or path,
        owner = existing and existing.owner or nil,
    }
end

--- Acquire exclusive ownership of one generated output path.
---@param path string Output path that a compile-like job intends to write.
---@param owner? table Metadata describing the job requesting the lease.
---@return table|nil lease Lease record that must be released by identity.
---@return table|nil error Failure payload with `reason`, `message`, and path metadata.
function M.acquire(path, owner)
    if type(path) ~= "string" or path == "" then
        return nil,
            {
                ok = false,
                reason = "invalid_path",
                message = "Output path is invalid",
                path = path,
            }
    end

    local key = key_for(path)
    local existing = leases[key]
    if existing then
        return nil, lease_error(path, existing)
    end

    next_id = next_id + 1
    local lease = {
        id = next_id,
        key = key,
        path = path,
        owner = owner or {},
    }
    leases[key] = lease
    return lease
end

--- Acquire multiple output-path leases atomically.
---@param items table|string[] Planned output records or path strings.
---@param owner? table Metadata describing the job requesting the leases.
---@return table[]|nil leases Lease records, or nil when any path cannot be leased.
---@return table|nil error Failure payload; any acquired leases are rolled back first.
function M.acquire_many(items, owner)
    local acquired = {}
    local seen = {}
    for _, item in ipairs(items or {}) do
        local path = type(item) == "table" and item.path or item
        if type(path) ~= "string" or path == "" then
            M.release_many(acquired)
            return nil,
                {
                    ok = false,
                    reason = "invalid_path",
                    message = "Output path is invalid",
                    path = path,
                }
        end

        local key = key_for(path)
        if seen[key] then
            M.release_many(acquired)
            return nil,
                {
                    ok = false,
                    reason = "duplicate_output",
                    message = "Multiple generated artifacts resolve to the same path",
                    duplicate_output = path,
                    path = path,
                }
        end
        seen[key] = true

        local lease, err = M.acquire(path, owner)
        if not lease then
            M.release_many(acquired)
            return nil, err
        end
        acquired[#acquired + 1] = lease
    end
    return acquired
end

--- Release one lease when it is still current for its path key.
---@param lease table Lease record returned by `acquire`.
---@return boolean released True when the active lease was removed.
function M.release(lease)
    if type(lease) ~= "table" or not lease.key then
        return false
    end
    local current = leases[lease.key]
    if current and current.id == lease.id then
        leases[lease.key] = nil
        return true
    end
    return false
end

--- Release a list of leases, ignoring nil or stale entries.
---@param items? table Lease records returned by `acquire_many`.
function M.release_many(items)
    for _, lease in ipairs(items or {}) do
        M.release(lease)
    end
end

--- Inspect active output-path leases.
---@param path? string Optional path whose active lease should be returned.
---@return table leases One lease when `path` is supplied, otherwise all leases by key.
function M.active(path)
    if path then
        return leases[key_for(path)]
    end
    local out = {}
    for key, lease in pairs(leases) do
        out[key] = lease
    end
    return out
end

--- Clear all in-memory output-path leases.
function M.reset()
    leases = {}
end

return M
