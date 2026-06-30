local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectPreviewService service Default preview service table.
function M.defaults()
    return {
        active = false,
    }
end

---@param project TypstProject? Project whose preview service is ensured.
---@return TypstProjectPreviewService? service Preview service table.
function M.ensure(project)
    local service = base.service(project, "preview")
    if not service then
        return nil
    end
    service.active = service.active == true
    return service
end

M.get = M.ensure

---@param project TypstProject Project whose preview service is mutated.
---@param fields TypstProjectPreviewServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectPreviewService? preview Preview service table.
function M.set(project, fields)
    local preview = base.update(project, "preview", fields)
    if preview then
        preview.active = preview.active == true
    end
    return preview
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe preview service snapshot.
function M.snapshot(project)
    local preview = M.ensure(project)
    return preview and (base.copy_value(preview, 3) or {}) or nil
end

return M
