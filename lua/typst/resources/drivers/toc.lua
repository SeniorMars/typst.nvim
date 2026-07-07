local log = require("typst.core.log")

local M = {}

---Close a project's TOC window during reset.
---@param project table Project state.
---@return table result Close summary.
function M.close_project(project)
    local ok, closed = pcall(require("typst.navigation.toc").close, project)
    if not ok then
        log.add("warn", "failed to close TOC during reset", {
            main = project and project.main or nil,
            error = closed,
        })
        return {
            ok = false,
            reason = "toc_close_failed",
            result = closed,
        }
    end
    return {
        ok = true,
        closed = closed == true,
    }
end

return M
