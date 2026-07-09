local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectViewerService service Default viewer service table.
function M.defaults()
    return {}
end

---@param project TypstProject? Project whose viewer service is ensured.
---@return TypstProjectViewerService? service Viewer service table.
function M.ensure(project)
    return base.service(project, "viewer")
end

M.get = M.ensure

---@param project TypstProject Project whose viewer service is mutated.
---@param fields TypstProjectViewerServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectViewerService? viewer Viewer service table.
function M.set(project, fields)
    return base.update(project, "viewer", fields)
end

--- Clear the last successful viewer backend recorded for a project.
---@param project TypstProject Project whose viewer service is mutated.
---@return TypstProjectViewerService? viewer Viewer service table.
function M.clear_last(project)
    return M.set(project, {
        clear = { "provider", "backend", "command", "cwd" },
    })
end

--- Record the viewer backend that successfully handled a project action.
---@param project TypstProject Project whose viewer service is mutated.
---@param fields {provider?:string,backend?:string,command?:string[]|string,cwd?:string}
---@return TypstProjectViewerService? viewer Viewer service table.
function M.record_last(project, fields)
    fields = fields or {}
    return M.set(project, {
        clear = { "provider", "backend", "command", "cwd" },
        provider = fields.provider,
        backend = fields.backend,
        command = fields.command,
        cwd = fields.cwd,
    })
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe viewer service snapshot.
function M.snapshot(project)
    local viewer = M.ensure(project)
    return viewer and (base.copy_value(viewer, 3) or {}) or nil
end

return M
