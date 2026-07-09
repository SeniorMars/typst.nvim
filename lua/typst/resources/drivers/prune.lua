local compiler_service = require("typst.project.services.compiler")
local core_result = require("typst.core.result")
local log = require("typst.core.log")
local preview_service = require("typst.project.services.preview")
local project_operations = require("typst.project.services.operations")
local resource_session = require("typst.resources.session")

local M = {}

local function compiler_module()
    return require("typst.compiler")
end

local function preview_module()
    return require("typst.preview.controller")
end

local function project_module()
    return require("typst.project")
end

local function toc_module()
    return require("typst.navigation.toc")
end

local function record_preview_stop_failure(project, prune_reason, result)
    preview_service.set(project, {
        active = true,
        stopping = type(result) == "table" and result.pending == true,
        status = "stopping_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason or "pending")
            or result,
        stop_prune_reason = prune_reason,
    })
end

local function stop_preview_before_prune(project, prune_reason)
    local preview_state = preview_service.get(project) or {}
    local preview_live = preview_state.active == true
        or preview_state.opening == true
        or preview_state.stopping == true
    if not project or next(project.bufs or {}) ~= nil or not preview_live then
        return nil
    end

    local ok, result = pcall(preview_module().stop, project, {
        lifecycle = true,
    })
    if not ok then
        log.add("warn", "failed to stop preview before project prune", {
            main = project.main,
            reason = prune_reason,
            error = result,
        })
        record_preview_stop_failure(project, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.pending == true then
        log.add("warn", "preview stop still pending before project prune", {
            main = project.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(project, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.ok == false then
        log.add("warn", "preview stop failed before project prune", {
            main = project.main,
            reason = prune_reason,
            stop_reason = result.reason,
            message = result.message,
        })
        record_preview_stop_failure(project, prune_reason, result)
        return false
    end

    if result == false then
        log.add("warn", "preview stop declined before project prune", {
            main = project.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(project, prune_reason, result)
        return false
    end

    return true
end

local function close_toc_before_prune(project)
    if not project or next(project.bufs or {}) ~= nil then
        return false
    end

    local ok, closed = pcall(toc_module().close, project)
    if not ok then
        log.add("warn", "failed to close TOC before project prune", {
            main = project.main,
            error = closed,
        })
        return false
    end

    return closed == true
end

local function active_non_compiler_resources(project, prune_reason)
    local session = resource_session.snapshot(project)
    if
        session
        and (
            (session.operations and session.operations.active > 0)
            or (session.operations and session.operations.retained > 0)
            or (session.outputs and session.outputs.active > 0)
        )
    then
        log.add("info", "retaining project with active resources", {
            main = project.main,
            reason = prune_reason,
            operations = session.operations,
            outputs = session.outputs,
        })
        return true
    end
    return false
end

---Stop project-owned resources before pruning an empty project.
---@param project table? Project state.
---@param opts? table Prune controls.
---@return table result Structured prune-attempt result.
function M.stop_before_prune(project, opts)
    opts = opts or {}
    local prune_reason = opts.reason or "resource_manager_prune"
    local log_message = opts.log_message
        or "stopping Typst resources before prune"

    if not project or next(project.bufs or {}) ~= nil then
        return {
            ok = true,
            attempted = false,
            reason = "project_has_buffers",
        }
    end

    local closed_toc = close_toc_before_prune(project)
    local stopped_preview = stop_preview_before_prune(project, prune_reason)
    local preview_failed = stopped_preview == false
    local compiler_state = compiler_service.get(project) or {}
    if not (compiler_state.watcher or compiler_state.process) then
        if preview_failed then
            return {
                ok = false,
                attempted = true,
                reason = "preview_stop_failed",
                retained = true,
            }
        end
        if stopped_preview or closed_toc then
            project_module().prune(project, prune_reason)
            return {
                ok = true,
                attempted = true,
                pruned = true,
                reason = prune_reason,
            }
        end
        if active_non_compiler_resources(project, prune_reason) then
            return {
                ok = true,
                attempted = true,
                retained = true,
                reason = "active_resources",
            }
        end
        return {
            ok = true,
            attempted = false,
            reason = "no_live_resources",
        }
    end

    log.add("info", log_message, { main = project.main })
    compiler_module().stop(project, function(result)
        if core_result.is_confirmed_stopped(result) then
            project_operations.clear(project, "compile")
            project_operations.clear(project, "watch")
            if not preview_failed then
                project_module().prune(project, prune_reason)
            end
            return
        end

        compiler_service.set(project, { status = "stopping_failed" })
        log.add("error", "retaining project with active resources", {
            main = project.main,
            reason = prune_reason,
            stop_result = result,
            preview_failed = preview_failed,
        })
    end)
    return {
        ok = true,
        attempted = true,
        pending = true,
        reason = "compiler_stop_started",
    }
end

return M
