local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        generation = 0,
        counters = {},
        subscribers = {},
        history = {},
    }
end

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
