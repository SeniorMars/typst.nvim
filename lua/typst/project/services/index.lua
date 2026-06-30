local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectIndexService service Default index service table.
function M.defaults()
    return {
        files = {},
        bibliographies = {},
        graph = {},
    }
end

---@param project TypstProject? Project whose index service is ensured.
---@return TypstProjectIndexService? service Index service table.
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

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe index service snapshot.
function M.snapshot(project)
    local index = M.ensure(project)
    return index and (base.copy_value(index, 2) or {}) or nil
end

return M
