local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectIntegrationsService service Default integration state.
function M.defaults()
    return {}
end

---@param project TypstProject? Project whose integration service is ensured.
---@return TypstProjectIntegrationsService? service Integration service table.
function M.ensure(project)
    return base.service(project, "integrations")
end

M.get = M.ensure

---@param project TypstProject Project whose integration service is mutated.
---@param fields TypstProjectIntegrationsServicePatch Fields to merge.
---@return TypstProjectIntegrationsService? service Integration service table.
function M.set(project, fields)
    return base.update(project, "integrations", fields)
end

---@param project TypstProject Project whose Tinymist status is recorded.
---@param status table Tinymist ensure status.
---@return TypstProjectIntegrationsService? service Integration service table.
function M.set_tinymist(project, status)
    return M.set(project, {
        tinymist = vim.tbl_extend("force", {
            checked_at = os.time(),
        }, status or {}),
    })
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe integration status.
function M.snapshot(project)
    local integrations = M.ensure(project)
    return integrations and (base.copy_value(integrations, 4) or {}) or nil
end

return M
