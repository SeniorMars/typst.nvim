local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectOperationsService service Default operations service table.
function M.defaults()
    return {
        active_by_id = {},
        active_by_kind = {},
        retained_by_id = {},
        retained_by_kind = {},
        generations = {},
        last = {},
        next_id = 0,
    }
end

---@param project TypstProject? Project whose operations service is ensured.
---@return TypstProjectOperationsService? service Operations service table.
function M.ensure(project)
    local service = base.service(project, "operations")
    if not service then
        return nil
    end
    service.active_by_id = service.active_by_id or {}
    service.active_by_kind = service.active_by_kind or {}
    service.retained_by_id = service.retained_by_id or {}
    service.retained_by_kind = service.retained_by_kind or {}
    service.generations = service.generations or {}
    service.last = service.last or {}
    service.next_id = service.next_id or 0
    return service
end

M.get = M.ensure

local function active_kinds(operations)
    local active = {}
    local seen = {}
    for kind, ids in pairs(operations.active_by_kind or {}) do
        if next(ids) ~= nil and not seen[kind] then
            active[#active + 1] = kind
            seen[kind] = true
        end
    end
    table.sort(active)
    return active
end

local function active_records(operations)
    local active = {}
    for id, record in pairs(operations.active_by_id or {}) do
        active[#active + 1] = {
            id = id,
            kind = record.kind,
            generation = record.generation,
            started_at = record.started_at,
        }
    end
    table.sort(active, function(left, right)
        return left.id < right.id
    end)
    return active
end

local function retained_records(operations)
    local retained = {}
    for id, record in pairs(operations.retained_by_id or {}) do
        retained[#retained + 1] = {
            id = id,
            kind = record.kind,
            generation = record.generation,
            started_at = record.started_at,
            retained_at = record.retained_at,
            result = base.copy_value(record.result, 3),
        }
    end
    table.sort(retained, function(left, right)
        return left.id < right.id
    end)
    return retained
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe operations service snapshot.
function M.snapshot(project)
    local operations = M.ensure(project)
    if not operations then
        return nil
    end
    return {
        active = active_kinds(operations),
        active_records = active_records(operations),
        retained_records = retained_records(operations),
        generations = base.copy_value(operations.generations or {}, 2) or {},
        last = base.copy_value(operations.last or {}, 4) or {},
    }
end

return M
