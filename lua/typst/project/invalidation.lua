local log = require("typst.core.log")
local services = require("typst.project.services")

local M = {}

local next_subscription_id = 0

local reason_events = {
    ["buffer changed"] = "buffer_changed",
    ["disk file changed"] = "disk_file_changed",
    ["dependency graph changed"] = "dependencies_changed",
    ["index provider changed"] = "provider_changed",
    manual = "manual",
}

local function live_project(project)
    if type(project) == "table" and project.mutable == false then
        return require("typst.project.context").live(project)
    end
    return project
end

local function ensure_bus(project)
    project = live_project(project)
    if type(project) ~= "table" then
        return nil
    end
    local bus = services.invalidation(project) or {}
    bus.generation = bus.generation or 0
    bus.counters = bus.counters or {}
    bus.subscribers = bus.subscribers or {}
    bus.history = bus.history or {}
    return bus
end

local function subscription_id()
    next_subscription_id = next_subscription_id + 1
    return next_subscription_id
end

--- Map an index invalidation reason to a stable event name.
---@param reason? string Human-readable invalidation reason.
---@return string event Invalidation event key.
function M.event_for_reason(reason)
    return reason_events[reason or ""] or "index_changed"
end

local function notify(project, event, payload)
    local bus = ensure_bus(project)
    local subscribers = bus.subscribers[event]
    if type(subscribers) ~= "table" then
        return
    end

    for id, callback in pairs(subscribers) do
        local ok, err = pcall(callback, payload, project)
        if not ok then
            log.add("warn", "project invalidation subscriber failed", {
                id = id,
                event = event,
                error = err,
            })
        end
    end
end

--- Emit a project invalidation event and update generation counters.
---@param project table Project state whose invalidation bus should emit.
---@param event? string Event key; defaults to `changed`.
---@param payload? table Event payload merged with project metadata.
---@return table? payload Emitted payload, or nil for invalid projects.
function M.emit(project, event, payload)
    project = live_project(project)
    if type(project) ~= "table" then
        return nil
    end

    event = event or "changed"
    local bus = ensure_bus(project)
    bus.generation = (bus.generation or 0) + 1
    bus.counters[event] = (bus.counters[event] or 0) + 1

    payload = vim.tbl_extend("force", payload or {}, {
        event = event,
        generation = bus.generation,
        project_key = project.key,
        root = project.root,
        main = project.main,
    })
    bus.last = payload
    bus.history[#bus.history + 1] = payload
    if #bus.history > 64 then
        table.remove(bus.history, 1)
    end

    notify(project, event, payload)
    notify(project, "*", payload)
    return payload
end

--- Emit an invalidation event derived from a human-readable reason.
---@param project table Project state whose invalidation bus should emit.
---@param reason string Human-readable invalidation reason.
---@param payload? table Event payload merged with reason/project metadata.
---@return table? payload Emitted payload, or nil for invalid projects.
function M.emit_reason(project, reason, payload)
    return M.emit(
        project,
        M.event_for_reason(reason),
        vim.tbl_extend("force", {
            reason = reason,
        }, payload or {})
    )
end

--- Subscribe to project invalidation events.
---@param project table Project state whose invalidation bus is observed.
---@param event? string Event key, or `*`/nil for all events.
---@param callback fun(payload:table, project:table) Subscriber callback.
---@return fun() unsubscribe Function that removes the subscriber.
function M.subscribe(project, event, callback)
    project = live_project(project)
    if type(project) ~= "table" then
        error("typst.nvim: project is required for invalidation subscription")
    end
    if type(callback) ~= "function" then
        error("typst.nvim: invalidation callback must be a function")
    end

    event = event or "*"
    local bus = ensure_bus(project)
    bus.subscribers[event] = bus.subscribers[event] or {}

    local id = subscription_id()
    bus.subscribers[event][id] = callback

    return function()
        if bus.subscribers[event] then
            bus.subscribers[event][id] = nil
        end
    end
end

--- Return the invalidation generation counter for a project.
---@param project table Project state whose invalidation bus is inspected.
---@param event? string Event-specific counter to read.
---@return integer generation Current generation count.
function M.generation(project, event)
    project = live_project(project)
    if type(project) ~= "table" then
        return 0
    end

    local bus = ensure_bus(project)
    if event then
        return bus.counters[event] or 0
    end
    return bus.generation or 0
end

--- Return a summary of invalidation state for reports/tests.
---@param project table Project state whose invalidation bus is inspected.
---@return table snapshot Invalidation generation, counters, and last payload.
function M.snapshot(project)
    project = live_project(project)
    if type(project) ~= "table" then
        return {
            generation = 0,
            counters = {},
            last = nil,
        }
    end

    local bus = ensure_bus(project)
    return {
        generation = bus.generation or 0,
        counters = vim.deepcopy(bus.counters or {}),
        last = vim.deepcopy(bus.last),
    }
end

--- Reset invalidation counters and subscribers for a project.
---@param project table Project state whose invalidation bus should reset.
function M.reset(project)
    project = live_project(project)
    if type(project) ~= "table" then
        return
    end

    services.ensure(project).invalidation = {
        generation = 0,
        counters = {},
        subscribers = {},
        history = {},
    }
end

return M
