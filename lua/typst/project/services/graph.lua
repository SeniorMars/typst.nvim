local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        files = {},
        file_sources = {},
        dependencies = {},
        dependency_sources = {},
    }
end

function M.ensure(project)
    local service = base.service(project, "graph")
    if not service then
        return nil
    end
    service.files = service.files or {}
    service.file_sources = service.file_sources or {}
    service.dependencies = service.dependencies or {}
    service.dependency_sources = service.dependency_sources or {}
    return service
end

M.get = M.ensure

function M.set(project, fields)
    local graph = base.update(project, "graph", fields)
    if graph then
        M.ensure(project)
    end
    return graph
end

function M.snapshot(project)
    local graph = M.ensure(project)
    if not graph then
        return nil
    end
    return {
        files = base.copy_value(graph.files, 3) or {},
        file_sources = base.copy_value(graph.file_sources, 3) or {},
        dependencies = base.copy_value(graph.dependencies, 3) or {},
        dependency_sources = base.copy_value(graph.dependency_sources, 3) or {},
    }
end

return M
