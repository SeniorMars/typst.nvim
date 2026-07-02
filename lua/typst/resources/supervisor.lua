local events = require("typst.core.events")
local log = require("typst.core.log")
local project_operations = require("typst.project.services.operations")
local preview_service = require("typst.project.services.preview")
local resource_session = require("typst.resources.session")

local M = {}

-- ResourceSupervisor is the cleanup migration boundary for project liveness.
-- Core lifecycle still contains the older reset implementation; this facade is
-- the high-level module runtime/project lifecycle code should call while
-- ownership moves behind it.

local function compiler_module()
    return require("typst.compiler")
end

local function preview_module()
    return require("typst.integrations.typst_preview")
end

function M.stop_before_prune(state, log_message, prune_reason)
    return require("typst.core.lifecycle").stop_before_prune(
        state,
        log_message,
        prune_reason
    )
end

---Return whether a project still owns live resources that block pruning.
---@param state TypstProject? Project state to inspect.
---@return boolean active True when project identity must be retained.
function M.has_active_resources(state)
    return resource_session.has_active(state)
end

---Return a summary-safe liveness snapshot for reports and tests.
---@param state TypstProject? Project state to inspect.
---@return table? snapshot Resource-session snapshot, or nil for invalid input.
function M.snapshot(state)
    return resource_session.snapshot(state)
end

function M.reset(opts)
    return require("typst.core.lifecycle").reset_project_resources(opts)
end

function M.stop_for_exit_all()
    events.emit_global("TypstEventQuit", {
        projects = vim.tbl_count(require("typst.project").all()),
    })
    for _, state in pairs(require("typst.project").all()) do
        if (preview_service.get(state) or {}).active then
            local ok = pcall(preview_module().stop_for_exit, state, {
                lifecycle = true,
                reason = "exit",
            })
            if not ok then
                preview_module().clear_state(state, {
                    lifecycle = true,
                    reason = "exit",
                })
            end
        end
        compiler_module().stop_for_exit(state)
        local cancelled = project_operations.cancel_project(state, {
            reason = "exit",
            timeout_ms = 100,
            kill_timeout_ms = 100,
            wait_timeout_ms = 250,
        })
        if (cancelled.failed or 0) > 0 or (cancelled.retained or 0) > 0 then
            log.add("warn", "project operations remained during exit", {
                main = state.main,
                summary = cancelled,
            })
        end
    end
end

return M
