local results = require("typst.preview.results")

local M = {}

---Create a backend wrapper for user-configured preview callbacks.
---@param preview_config table Preview config table.
---@return table backend Callback preview backend.
function M.create(preview_config)
    preview_config = preview_config or {}
    return {
        name = "callback",
        kind = "callback",

        open = function(_, project, opts)
            local ok, result = pcall(preview_config.open, project, opts)
            if not ok then
                return results.callback_error(project, "open", result)
            end
            return result
        end,

        stop = function(_, project, opts)
            if type(preview_config.stop) ~= "function" then
                return results.failed(
                    "unsupported",
                    "No Typst preview stop callback is configured",
                    { backend = "callback" }
                )
            end
            local ok, result = pcall(preview_config.stop, project, opts)
            if not ok then
                return results.callback_error(project, "stop", result)
            end
            return result
        end,

        refresh = function(_, project, compile_result, opts)
            if type(preview_config.refresh) ~= "function" then
                return nil
            end
            local ok, result =
                pcall(preview_config.refresh, project, compile_result, opts)
            if not ok then
                return results.callback_error(project, "refresh", result)
            end
            return result
        end,
    }
end

return M
