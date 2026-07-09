local native = require("typst.preview.native")

local M = {}

---Deprecated compatibility facade for the old native preview backend path.
---@return table backend Native preview backend shim.
function M.create()
    return {
        name = "native",
        kind = "native",
        compat = true,

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
