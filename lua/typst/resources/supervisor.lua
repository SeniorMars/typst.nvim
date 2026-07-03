local events = require("typst.core.events")
local log = require("typst.core.log")
local core_result = require("typst.core.result")
local compiler_service = require("typst.project.services.compiler")
local project_operations = require("typst.project.services.operations")
local preview_service = require("typst.project.services.preview")
local resource_session = require("typst.resources.session")

local M = {}

-- ResourceSupervisor is the cleanup authority for project liveness. Project
-- modules decide identity and buffer membership; this module decides when live
-- compiler, preview, operation, TOC, and output resources block pruning/reset.

local function compiler_module()
    return require("typst.compiler")
end

local function preview_module()
    return require("typst.integrations.typst_preview")
end

local function toc_module()
    return require("typst.navigation.toc")
end

local function core_lifecycle()
    return require("typst.core.lifecycle")
end

local function project_module()
    return require("typst.project")
end

local function project_store()
    return require("typst.project.store")
end

local function record_preview_stop_failure(state, prune_reason, result)
    preview_service.set(state, {
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

local function stop_preview_before_prune(state, prune_reason)
    local preview_state = preview_service.get(state) or {}
    if
        not state
        or next(state.bufs or {}) ~= nil
        or not preview_state.active
    then
        return nil
    end

    local ok, result = pcall(preview_module().stop, state, { lifecycle = true })
    if not ok then
        log.add("warn", "failed to stop preview before project prune", {
            main = state.main,
            reason = prune_reason,
            error = result,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.pending == true then
        log.add("warn", "preview stop still pending before project prune", {
            main = state.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.ok == false then
        log.add("warn", "preview stop failed before project prune", {
            main = state.main,
            reason = prune_reason,
            stop_reason = result.reason,
            message = result.message,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if result == false then
        log.add("warn", "preview stop declined before project prune", {
            main = state.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    return true
end

local function close_toc_before_prune(state)
    if not state or next(state.bufs or {}) ~= nil then
        return false
    end

    local ok, closed = pcall(toc_module().close, state)
    if not ok then
        log.add("warn", "failed to close TOC before project prune", {
            main = state.main,
            error = closed,
        })
        return false
    end

    return closed == true
end

--- Stop project-owned UI/compiler resources before removing an empty project.
---@param state? table Project state that may be pruned.
---@param log_message string Message logged when compiler shutdown is requested.
---@param prune_reason string Reason passed through to project pruning.
---@return boolean attempted True when teardown or prune work was attempted.
function M.stop_before_prune(state, log_message, prune_reason)
    if not state or next(state.bufs or {}) ~= nil then
        return false
    end

    local project = project_module()
    local closed_toc = close_toc_before_prune(state)
    local stopped_preview = stop_preview_before_prune(state, prune_reason)
    local preview_failed = stopped_preview == false
    local compiler_state = compiler_service.get(state) or {}
    if not (compiler_state.watcher or compiler_state.process) then
        if preview_failed then
            return true
        end
        if stopped_preview or closed_toc then
            project.prune(state, prune_reason)
            return true
        end
        local session = resource_session.snapshot(state)
        if
            session
            and (
                (session.operations and session.operations.active > 0)
                or (session.operations and session.operations.retained > 0)
                or (session.outputs and session.outputs.active > 0)
            )
        then
            log.add("info", "retaining project with active resources", {
                main = state.main,
                reason = prune_reason,
                operations = session.operations,
                outputs = session.outputs,
            })
            return true
        end
        return false
    end

    log.add("info", log_message, { main = state.main })
    compiler_module().stop(state, function(result)
        if core_result.is_confirmed_stopped(result) then
            project_operations.clear(state, "compile")
            project_operations.clear(state, "watch")
            if not preview_failed then
                project.prune(state, prune_reason)
            end
            return
        end

        compiler_service.set(state, { status = "stopping_failed" })
        log.add("error", "retaining project with active resources", {
            main = state.main,
            reason = prune_reason,
            stop_result = result,
            preview_failed = preview_failed,
        })
    end)
    return true
end

--- Return whether a project still owns live resources that block pruning.
---@param state TypstProject? Project state to inspect.
---@return boolean active True when project identity must be retained.
function M.has_active_resources(state)
    return resource_session.has_active(state)
end

--- Return a summary-safe liveness snapshot for reports and tests.
---@param state TypstProject? Project state to inspect.
---@return table? snapshot Resource-session snapshot, or nil for invalid input.
function M.snapshot(state)
    return resource_session.snapshot(state)
end

local function clear_lifecycle_compile_handle(state)
    local compiler_state = compiler_service.get(state) or {}
    if state and compiler_state.stopping_compile then
        compiler_service.set(state, {
            clear = { "process", "active_compile_deps_path" },
            status = "idle",
        })
    end
end

local function stop_compiler_for_reset(state, opts)
    opts = opts or {}
    local compiler_state = compiler_service.get(state) or {}
    if
        not (
            compiler_state.process
            or compiler_state.watcher
            or compiler_state.stopping_compile
        )
    then
        compiler_service.set(state, {
            clear = { "process", "watcher" },
            status = "idle",
        })
        return {
            code = 0,
            stopped = true,
            idle = true,
        }
    end

    local done = false
    local result = nil
    local ok, err = pcall(compiler_module().stop, state, function(stop_result)
        result = stop_result
        done = true
    end)
    if not ok then
        log.add("warn", "failed to stop compiler during reset", {
            main = state.main,
            error = err,
        })
        result = {
            code = 1,
            stopped = false,
            error = err,
        }
        done = true
    end

    if not done then
        local timeout_ms = opts.timeout_ms or 1500
        vim.wait(timeout_ms, function()
            return done
        end, 10, false)
        if not done then
            log.add(
                "warn",
                "compiler stop timed out during reset; forcing shutdown",
                {
                    main = state.main,
                    timeout_ms = timeout_ms,
                }
            )
            local forced_ok, forced_result =
                pcall(compiler_module().stop_for_exit, state, {
                    timeout_ms = opts.force_timeout_ms or 250,
                    kill_timeout_ms = opts.force_kill_timeout_ms or 250,
                })
            result = forced_ok and forced_result
                or {
                    code = 1,
                    stopped = false,
                    error = forced_result,
                }
            done = true
        end
    end

    if core_result.is_confirmed_stopped(result) then
        clear_lifecycle_compile_handle(state)
        compiler_service.set(state, {
            clear = { "process", "watcher", "stopping_compile" },
            status = "idle",
        })
    else
        compiler_service.set(state, { status = "stopping_failed" })
        log.add(
            "error",
            "retaining compiler resources after reset stop failed",
            {
                main = state.main,
                result = result,
            }
        )
    end
    return result
end

local function reset_failed(summary, state, reason, result)
    summary.ok = false
    summary.failed[#summary.failed + 1] = {
        main = state and state.main,
        reason = reason,
        result = result,
    }
end

--- Stop project resources and clear buffer lifecycle state during plugin reset.
---@param opts? table Reset controls; `force=true` clears state even when stops fail.
---@return table summary Reset status with failed project details.
function M.reset(opts)
    opts = opts or {}
    local states = vim.tbl_values(project_store().all())
    local summary = {
        ok = true,
        projects = #states,
        failed = {},
    }
    for _, state in ipairs(states) do
        state.resetting = true
        for bufnr in pairs(state.bufs or {}) do
            core_lifecycle().clear_buffer(bufnr)
        end

        pcall(toc_module().close, state)

        if (preview_service.get(state) or {}).active then
            local ok, result = pcall(
                preview_module().stop,
                state,
                { lifecycle = true, reset = true }
            )
            if not ok then
                log.add("warn", "failed to stop preview during reset", {
                    main = state.main,
                    error = result,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_error", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif type(result) == "table" and result.pending == true then
                log.add("warn", "preview stop pending during reset", {
                    main = state.main,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_pending", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif type(result) == "table" and result.ok == false then
                log.add("warn", "preview stop failed during reset", {
                    main = state.main,
                    reason = result.reason,
                    message = result.message,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_failed", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif result == false then
                log.add("warn", "preview stop declined during reset", {
                    main = state.main,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_declined", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            end
        end

        local stopped = stop_compiler_for_reset(state, opts)
        if not core_result.is_confirmed_stopped(stopped) then
            reset_failed(summary, state, "compiler_stop_failed", stopped)
        end
        local cancelled = project_operations.cancel_project(state, {
            reason = "reset",
            timeout_ms = opts.operation_timeout_ms or 250,
            kill_timeout_ms = opts.operation_kill_timeout_ms or 250,
            wait_timeout_ms = opts.operation_wait_timeout_ms or 1000,
        })
        if cancelled.failed > 0 then
            log.add(
                "warn",
                "failed to cancel all project operations during reset",
                {
                    main = state.main,
                    summary = cancelled,
                }
            )
            reset_failed(summary, state, "operation_cancel_failed", cancelled)
        end
        if (cancelled.retained or 0) > 0 then
            log.add(
                "warn",
                "retained orphaned project operations during reset",
                {
                    main = state.main,
                    summary = cancelled,
                }
            )
            reset_failed(summary, state, "operation_orphan_retained", cancelled)
        end
        state.resetting = false
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        core_lifecycle().clear_buffer(bufnr)
    end

    return summary
end

function M.stop_for_exit_all()
    local states = project_store().all()
    events.emit_global("TypstEventQuit", {
        projects = vim.tbl_count(states),
    })
    for _, state in pairs(states) do
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
