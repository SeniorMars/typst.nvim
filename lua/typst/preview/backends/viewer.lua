local interface = require("typst.preview.backends.interface")
local native = require("typst.preview.native")

local M = {}

---Create a backend wrapper for boring artifact-to-viewer preview.
---@return table backend Viewer preview backend.
function M.create()
    return interface.create({
        name = "viewer",
        kind = "viewer",

        open = function(_, project, opts)
            return native.open_viewer(project, opts)
        end,
    })
end

return M
