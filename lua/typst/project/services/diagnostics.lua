local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        buffers = {},
    }
end

function M.ensure(project)
    local service = base.service(project, "diagnostics")
    if not service then
        return nil
    end
    service.buffers = service.buffers or {}
    return service
end

M.get = M.ensure

function M.set(project, fields)
    local diagnostics = base.update(project, "diagnostics", fields)
    if diagnostics then
        diagnostics.buffers = diagnostics.buffers or {}
    end
    return diagnostics
end

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
