local log = require("typst.core.log")
local resource_session = require("typst.resources.session")

local M = {}

---Cancel runtime-global operations during reset.
---@param ctx table Reset driver context.
---@return table result Global operation reset summary.
function M.cancel_all(ctx)
    ctx = ctx or {}
    local opts = ctx.opts or {}
    local ok, global_operations = xpcall(function()
        return resource_session.reset_global_operations({
            force = opts.force == true,
            reason = opts.reason or "reset",
            timeout_ms = opts.operation_timeout_ms or 250,
            kill_timeout_ms = opts.operation_kill_timeout_ms or 250,
        })
    end, debug.traceback)
    if ok then
        if
            type(global_operations) == "table"
            and global_operations.ok == false
        then
            log.add("warn", "global operations remained during reset", {
                summary = global_operations,
            })
            return {
                ok = false,
                reason = "global_operations_remain",
                result = global_operations,
            }
        end
        return {
            ok = true,
            result = global_operations,
        }
    end

    log.add("error", "global operation reset failed", {
        error = global_operations,
    })
    return {
        ok = false,
        reason = "global_operation_reset_error",
        result = global_operations,
    }
end

return M
