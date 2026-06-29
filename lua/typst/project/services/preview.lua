local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        active = false,
    }
end

function M.ensure(project)
    local service = base.service(project, "preview")
    if not service then
        return nil
    end
    service.active = service.active == true
    return service
end

M.get = M.ensure

function M.set(project, fields)
    local preview = base.update(project, "preview", fields)
    if preview then
        preview.active = preview.active == true
    end
    return preview
end

function M.snapshot(project)
    local preview = M.ensure(project)
    return preview and (base.copy_value(preview, 3) or {}) or nil
end

return M
