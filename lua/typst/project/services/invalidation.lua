local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectInvalidationService service Default invalidation service table.
function M.defaults()
    return {
        generation = 0,
        counters = {},
        subscribers = {},
        history = {},
    }
end

---@param project TypstProject? Project whose invalidation service is ensured.
---@return TypstProjectInvalidationService? service Invalidation service table.
function M.ensure(project)
    local service = base.service(project, "invalidation")
    if not service then
        return nil
    end
    service.generation = service.generation or 0
    service.counters = service.counters or {}
    service.subscribers = service.subscribers or {}
    service.history = service.history or {}
    return service
end

M.get = M.ensure

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe invalidation service snapshot.
function M.snapshot(project)
    local invalidation = M.ensure(project)
    if not invalidation then
        return nil
    end
    return {
        generation = invalidation.generation or 0,
        counters = base.copy_value(invalidation.counters, 3) or {},
        last = base.copy_value(invalidation.last, 3),
    }
end

return M
