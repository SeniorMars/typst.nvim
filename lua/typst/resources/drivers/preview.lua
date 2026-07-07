local log = require("typst.core.log")
local preview_controller = require("typst.preview.controller")
local preview_results = require("typst.preview.results")
local preview_service = require("typst.project.services.preview")
local state = require("typst.preview.state_machine")

local M = {}

local function force_clear(project)
    preview_controller.clear_state(project, {
        lifecycle = true,
        reset = true,
        reason = "reset",
    })
end

local function preview_blocker(project, reason, result)
    return {
        scope = "project",
        kind = reason,
        severity = "blocked",
        project_key = project.key,
        main = project.main,
        message = "Typst preview stop was not confirmed",
        recovery = "Run :TypstReset! to discard typst.nvim preview state if the backend already stopped",
        result = type(result) == "table" and preview_results.compact(result)
            or result,
    }
end

---Stop active preview resources for a project during reset.
---@param ctx table Reset driver context.
---@param project table Project state.
---@return table result Stop summary.
function M.stop_project(ctx, project)
    ctx = ctx or {}
    local opts = ctx.opts or {}
    local preview = preview_service.get(project) or {}
    if
        preview.active ~= true
        and preview.opening ~= true
        and preview.stopping ~= true
    then
        return { ok = true, idle = true }
    end

    local force = ctx.force == true or opts.force == true
    local ok, result = pcall(preview_controller.stop, project, {
        lifecycle = true,
        reset = true,
        reason = opts.reason or "reset",
        force = force,
    })
    if not ok then
        log.add("warn", "failed to stop preview during reset", {
            main = project.main,
            error = result,
        })
        state.to_stopping_failed(project, result)
        if force then
            force_clear(project)
        end
        return {
            ok = false,
            reason = "preview_stop_error",
            retained = not force,
            result = result,
            blockers = {
                preview_blocker(project, "preview_stop_error", result),
            },
        }
    end

    if preview_results.is_pending(result) then
        log.add("warn", "preview stop pending during reset", {
            main = project.main,
        })
        state.to_stop_unconfirmed(project, result, "reset")
        if force then
            force_clear(project)
        end
        return {
            ok = false,
            reason = "preview_stop_pending",
            retained = not force,
            result = result,
            blockers = {
                preview_blocker(project, "preview_stop_pending", result),
            },
        }
    end

    if preview_results.stop_failed(result) then
        log.add("warn", "preview stop failed during reset", {
            main = project.main,
            reason = type(result) == "table" and result.reason or nil,
            message = type(result) == "table" and result.message or nil,
        })
        state.to_stopping_failed(project, result)
        if force then
            force_clear(project)
        end
        return {
            ok = false,
            reason = type(result) == "table" and result.reason
                or "preview_stop_failed",
            retained = not force,
            result = result,
            blockers = {
                preview_blocker(project, "preview_stop_failed", result),
            },
        }
    end

    return {
        ok = true,
        result = result,
    }
end

---Stop active preview resources during exit cleanup.
---@param ctx table Exit driver context.
---@param project table Project state.
---@return table result Exit stop summary.
function M.stop_for_exit_project(ctx, project)
    ctx = ctx or {}
    local result = preview_controller.stop_for_exit(project, {
        lifecycle = true,
        exit = true,
        reason = (ctx.opts and ctx.opts.reason) or "exit",
    })
    if
        preview_results.is_pending(result)
        or preview_results.stop_failed(result)
    then
        return {
            ok = false,
            reason = "preview_stop_unconfirmed",
            result = result,
            blockers = {
                preview_blocker(project, "preview_stop_unconfirmed", result),
            },
        }
    end
    return { ok = true, result = result }
end

---Return preview resource status for a project.
---@param _ctx table? Driver context.
---@param project table Project state.
---@return table status Preview status.
function M.snapshot(_ctx, project)
    return preview_controller.status(project, { raw = true })
end

return M
