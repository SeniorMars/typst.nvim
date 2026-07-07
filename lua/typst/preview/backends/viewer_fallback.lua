local native = require("typst.preview.native")

local M = {}

---Create a backend wrapper for viewer fallback preview.
---@return table backend Viewer fallback backend.
function M.create()
    return {
        name = "viewer-fallback",
        kind = "viewer",
        open = function(_, project, opts)
            return native.open_viewer(project, opts)
        end,
    }
end

return M
