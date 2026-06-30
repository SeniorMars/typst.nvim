local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectDiagnosticsService service Default diagnostics service table.
function M.defaults()
    return {
        buffers = {},
    }
end

---@param project TypstProject? Project whose diagnostics service is ensured.
---@return TypstProjectDiagnosticsService? service Diagnostics service table.
function M.ensure(project)
    local service = base.service(project, "diagnostics")
    if not service then
        return nil
    end
    service.buffers = service.buffers or {}
    return service
end

M.get = M.ensure

---@param project TypstProject Project whose diagnostics service is mutated.
---@param fields TypstProjectDiagnosticsServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectDiagnosticsService? diagnostics Diagnostics service table.
function M.set(project, fields)
    local diagnostics = base.update(project, "diagnostics", fields)
    if diagnostics then
        diagnostics.buffers = diagnostics.buffers or {}
    end
    return diagnostics
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe diagnostics service snapshot.
function M.snapshot(project)
    local diagnostics = M.ensure(project)
    if not diagnostics then
        return nil
    end
    return {
        buffers = base.copy_value(diagnostics.buffers or {}, 3) or {},
    }
end

return M
