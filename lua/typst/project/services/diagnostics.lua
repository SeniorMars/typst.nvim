local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectDiagnosticsService service Default diagnostics service table.
function M.defaults()
    return {
        buffers = {},
        last_publish = nil,
        quickfix_by_source = {},
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
    service.quickfix_by_source = service.quickfix_by_source or {}
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
        diagnostics.quickfix_by_source = diagnostics.quickfix_by_source or {}
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
        last_publish = base.copy_value(diagnostics.last_publish, 3),
        quickfix_by_source = base.copy_value(
            diagnostics.quickfix_by_source or {},
            4
        ) or {},
    }
end

return M
