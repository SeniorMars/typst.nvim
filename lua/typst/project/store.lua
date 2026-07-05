local index_cache = require("typst.project.index.cache")
local log = require("typst.core.log")
local project_model = require("typst.project.model")
local project_registry = require("typst.project.registry")
local resource_supervisor = require("typst.resources.supervisor")

local M = {}

-- ProjectStore owns live project identity and buffer membership. Registry keeps
-- the raw tables; callers should use this facade for project creation, lookup,
-- encoded command keys, and prune bookkeeping.

M.project_key = project_model.project_key
M.encode_key = project_registry.encode_key
M.decode_key = project_registry.decode_key
M.resolve_key = project_registry.resolve_key
M.get_encoded = project_registry.get_encoded

function M.all()
    return project_registry.all()
end

function M.buffers()
    return project_registry.buffers()
end

function M.get(key)
    return project_registry.get(key)
end

function M.create(root, main)
    local key = M.project_key(root, main)
    local project = project_registry.get(key)
    if project then
        return project, false
    end

    project = project_model.new_project(root, main, key)
    project_registry.set(key, project)
    log.add("info", "created project", { root = root, main = main })
    return project, true
end

function M.remove(key)
    return project_registry.remove(key)
end

function M.key_for_buffer(bufnr)
    return project_registry.key_for_buffer(bufnr)
end

function M.project_for_buffer(bufnr)
    return project_registry.project_for_buffer(bufnr)
end

function M.set_buffer(bufnr, key)
    return project_registry.set_buffer(bufnr, key)
end

function M.clear_buffer(bufnr)
    return project_registry.clear_buffer(bufnr)
end

---@param state TypstProject? Project that may be pruned.
---@param reason string Prune reason.
---@return boolean pruned True when the project was removed.
function M.prune_if_empty(state, reason)
    if
        not state
        or next(state.bufs or {}) ~= nil
        or resource_supervisor.has_active_resources(state)
    then
        return false
    end

    M.remove(state.key)
    index_cache.reset(state)
    state._typst_project_pruned = true
    state._typst_project_pruned_reason = reason
    log.add("info", "removed empty project", {
        main = state.main,
        reason = reason,
    })
    return true
end

---@param state TypstProject? Project that may have been pruned.
---@param reason? string Event reason override.
---@return boolean emitted True when a prune event was emitted.
function M.emit_project_pruned(state, reason)
    if
        not state
        or state._typst_project_pruned ~= true
        or state._typst_project_pruned_event_emitted == true
    then
        return false
    end

    state._typst_project_pruned_event_emitted = true
    require("typst.core.events").emit("TypstProjectPruned", state, {
        event_kind = "project_pruned",
        reason = reason or state._typst_project_pruned_reason,
        remaining_buffers = 0,
        project_pruned = true,
    })
    return true
end

--- Prune a project if it no longer owns buffers or active resources.
---@param state TypstProject|string Project state or project key.
---@param reason? string Human-readable prune reason.
---@return boolean? pruned True when the project was removed.
function M.prune(state, reason)
    ---@type TypstProject?
    local resolved
    if type(state) == "string" then
        resolved = M.get(state)
    elseif type(state) == "table" then
        resolved = state
    end
    if not resolved then
        return false
    end

    local pruned = M.prune_if_empty(resolved, reason or "manual prune")
    if pruned then
        M.emit_project_pruned(resolved, reason or "manual prune")
    end
    return pruned
end

function M.reset()
    project_registry.reset()
end

return M
