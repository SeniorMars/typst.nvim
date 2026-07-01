local path_leases = require("typst.core.path_leases")
local util = require("typst.core.util")

local M = {}

-- Project-scoped output ownership facade.
--
-- Low-level lease storage lives in core.path_leases. This module is the
-- compile/render/export-facing boundary so generated output ownership can be
-- reported and migrated without each workflow knowing lease internals.

function M.owner(kind, project, fields)
    return vim.tbl_extend("force", {
        kind = kind,
        project_key = project and project.key or nil,
        main = project and project.main or nil,
    }, fields or {})
end

function M.ensure_parent(path)
    return util.ensure_parent(path)
end

function M.acquire(path, owner)
    return path_leases.acquire(path, owner)
end

function M.acquire_many(items, owner)
    return path_leases.acquire_many(items, owner)
end

function M.release(lease)
    return path_leases.release(lease)
end

function M.release_many(leases)
    return path_leases.release_many(leases)
end

function M.active(path)
    return path_leases.active(path)
end

function M.active_for_project(project)
    local out = {}
    local key = project and project.key
    for lease_key, lease in pairs(path_leases.active()) do
        if lease.owner and lease.owner.project_key == key then
            out[lease_key] = lease
        end
    end
    return out
end

function M.snapshot(project)
    local out = {}
    for lease_key, lease in pairs(M.active_for_project(project)) do
        out[#out + 1] = {
            key = lease_key,
            path = lease.path,
            owner = vim.deepcopy(lease.owner or {}),
        }
    end
    table.sort(out, function(left, right)
        return (left.path or left.key or "") < (right.path or right.key or "")
    end)
    return out
end

function M.reset()
    return path_leases.reset()
end

return M
