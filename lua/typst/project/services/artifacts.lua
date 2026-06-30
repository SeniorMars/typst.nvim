local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectArtifactsService service Default artifact service table.
function M.defaults()
    return {
        items = {},
    }
end

---@param project TypstProject? Project whose artifact service is ensured.
---@return TypstProjectArtifactsService? service Artifact service table.
function M.ensure(project)
    local service = base.service(project, "artifacts")
    if not service then
        return nil
    end
    service.items = service.items or {}
    return service
end

M.get = M.ensure

---@param project TypstProject Project whose artifact service is mutated.
---@param fields TypstProjectArtifactsServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectArtifactsService? artifacts Artifact service table.
function M.set(project, fields)
    local artifacts = base.update(project, "artifacts", fields)
    if artifacts then
        artifacts.items = artifacts.items or {}
    end
    return artifacts
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe artifact service snapshot.
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
