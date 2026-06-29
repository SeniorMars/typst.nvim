local base = require("typst.project.services.base")

local M = {}

function M.defaults()
    return {
        status = "idle",
        generation = 0,
        watch_generation = 0,
        watch_cycle_generation = 0,
    }
end

function M.ensure(project)
    local service = base.service(project, "compiler")
    if not service then
        return nil
    end
    service.status = service.status or "idle"
    service.generation = service.generation or 0
    service.watch_generation = service.watch_generation or 0
    service.watch_cycle_generation = service.watch_cycle_generation or 0
    return service
end

M.get = M.ensure

function M.set(project, fields)
    local compiler = base.update(project, "compiler", fields)
    if compiler then
        M.ensure(project)
    end
    return compiler
end

function M.has_active(service)
    service = service or {}
    return service.process ~= nil
        or service.watcher ~= nil
        or service.stopping_compile ~= nil
end

function M.snapshot(project)
    local compiler = M.ensure(project)
    if not compiler then
        return nil
    end
    return {
        status = compiler.status,
        generation = compiler.generation,
        watch_generation = compiler.watch_generation,
        watch_cycle_generation = compiler.watch_cycle_generation,
        has_process = compiler.process ~= nil,
        has_watcher = compiler.watcher ~= nil,
        stopping = compiler.stopping_compile ~= nil,
        last_cwd = compiler.last_cwd,
        last_profile = compiler.last_profile,
        output = compiler.output,
    }
end

return M
