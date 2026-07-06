local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectLifecycleService service Default lifecycle status.
function M.defaults()
    return {}
end

---@param project TypstProject? Project whose lifecycle service is ensured.
---@return TypstProjectLifecycleService? service Lifecycle service table.
function M.ensure(project)
    return base.service(project, "lifecycle")
end

M.get = M.ensure

---@param project TypstProject Project whose lifecycle service is mutated.
---@param fields TypstProjectLifecycleServicePatch Fields to merge.
---@return TypstProjectLifecycleService? service Lifecycle service table.
function M.set(project, fields)
    return base.update(project, "lifecycle", fields)
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe lifecycle status.
function M.snapshot(project)
    local lifecycle = M.ensure(project)
    return lifecycle and (base.copy_value(lifecycle, 4) or {}) or nil
end

return M
