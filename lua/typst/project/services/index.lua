local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        files = {},
        bibliographies = {},
        graph = {},
    }
end

function M.ensure(project)
    local service = base.service(project, "index")
    if not service then
        return nil
    end
    service.files = service.files or {}
    service.bibliographies = service.bibliographies or {}
    service.graph = service.graph or {}
    return service
end

M.get = M.ensure

function M.snapshot(project)
    local index = M.ensure(project)
    return index and (base.copy_value(index, 2) or {}) or nil
end

return M
