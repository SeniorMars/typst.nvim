local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {}
end

function M.ensure(project)
    return base.service(project, "viewer")
end

M.get = M.ensure

function M.set(project, fields)
    return base.update(project, "viewer", fields)
end

function M.snapshot(project)
    local viewer = M.ensure(project)
    return viewer and (base.copy_value(viewer, 3) or {}) or nil
end

return M
