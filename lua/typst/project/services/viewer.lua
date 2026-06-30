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

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe viewer service snapshot.
function M.snapshot(project)
    local viewer = M.ensure(project)
    return viewer and (base.copy_value(viewer, 3) or {}) or nil
end

return M
