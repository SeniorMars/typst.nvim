local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        items = {},
    }
end

function M.ensure(project)
    local service = base.service(project, "artifacts")
    if not service then
        return nil
    end
    service.items = service.items or {}
    return service
end

M.get = M.ensure

function M.set(project, fields)
    local artifacts = base.update(project, "artifacts", fields)
    if artifacts then
        artifacts.items = artifacts.items or {}
    end
    return artifacts
end

function M.snapshot(project)
    local artifacts = M.ensure(project)
    if not artifacts then
        return nil
    end
    return {
        count = #(artifacts.items or {}),
        last = base.copy_value(artifacts.last, 3),
        output = artifacts.output,
    }
end

return M
