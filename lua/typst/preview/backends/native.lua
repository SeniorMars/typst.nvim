local native = require("typst.preview.native")

local M = {}

---Create a backend wrapper for typst.nvim native preview.
---@return table backend Native preview backend.
function M.create()
    return {
        name = "native",
        kind = "native",

        open = function(_, project, opts)
            return native.open(project, opts)
        end,

        stop = function(_, project)
            native.stop(project)
            return {
                ok = true,
                stopped = true,
                backend = "native-browser",
            }
        end,

        refresh = function(_, project, compile_result, opts)
            return native.refresh(project, compile_result, opts)
        end,
    }
end

return M
