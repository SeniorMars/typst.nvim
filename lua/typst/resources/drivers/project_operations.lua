local log = require("typst.core.log")
local project_operations = require("typst.project.services.operations")

local M = {}

---Cancel project-scoped operations during reset.
---@param ctx table Reset driver context.
---@param project table Project state.
---@return table result Cancellation summary.
function M.cancel_project(ctx, project)
    ctx = ctx or {}
    local opts = ctx.opts or {}
    local cancelled = project_operations.cancel_project(project, {
        reason = opts.reason or "reset",
        timeout_ms = opts.operation_timeout_ms or 250,
        kill_timeout_ms = opts.operation_kill_timeout_ms or 250,
        wait_timeout_ms = opts.operation_wait_timeout_ms or 1000,
    })
    local failures = {}
    if cancelled.failed > 0 then
        log.add(
            "warn",
            "failed to cancel all project operations during reset",
            {
                main = project.main,
                summary = cancelled,
            }
        )
        failures[#failures + 1] = {
            reason = "operation_cancel_failed",
            result = cancelled,
        }
    end
    if (cancelled.retained or 0) > 0 then
        log.add("warn", "retained orphaned project operations during reset", {
            main = project.main,
            summary = cancelled,
        })
        failures[#failures + 1] = {
            reason = "operation_orphan_retained",
            result = cancelled,
        }
    end
    return {
        ok = #failures == 0,
        result = cancelled,
        failures = failures,
    }
end

return M
