local log = require("typst.core.log")

local M = {}

--- Normalize a user callback result that may optionally provide a path.
---
--- Configured root/main callbacks are allowed to decline by returning nil or
--- false. Any other non-string value is ignored with a warning so a bad user
--- callback cannot crash project attachment in path resolution.
---@param value any Callback return value.
---@param source string Human-readable callback source.
---@param fields? table Additional log fields.
---@return string|nil path Valid non-empty path string, or nil when absent/invalid.
function M.optional_path(value, source, fields)
    if value == nil or value == false then
        return nil
    end

    if type(value) == "string" and value ~= "" then
        return value
    end

    local log_fields = vim.tbl_extend("force", fields or {}, {
        source = source,
        result_type = type(value),
    })
    log.add("warn", "ignored invalid Typst path callback result", log_fields)
    return nil
end

return M
