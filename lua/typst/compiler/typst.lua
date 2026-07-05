local compiler_compile = require("typst.compiler.typst_compile")
local compiler_process = require("typst.compiler.typst_process")
local compiler_watcher = require("typst.compiler.typst_watcher")
local compiler_result = require("typst.compiler.state_machine")
local log = require("typst.core.log")
local compiler_service = require("typst.project.services.compiler")
local restart_handle = require("typst.core.restart_handle")

local M = {}

-- Built-in Typst compiler coordinator.
--
-- Compile and watch share one process slot per project. Starting one mode first
-- stops the other, and queued restarts preserve the caller's callback once the
-- old process actually exits.
local function should_finish_restart(result)
    return not (
        type(result) == "table"
        and result.watch == true
        and result.stopped ~= true
    )
end

local function wrap_restart_callback(restart, callback)
    return function(result, ...)
        if should_finish_restart(result) then
            restart:finish(result)
        end
        if callback then
            callback(result, ...)
        end
    end
end

--- Start a built-in one-shot Typst compile, replacing active compiler work.
---@param project table Project state whose built-in compiler slot is used.
---@param callback? fun(result:TypstCompilerResult) Terminal compile or stop-failure callback.
---@param run_config? table Effective run configuration for this invocation.
---@return unknown handle Compile or stop handle for the active transition.
function M.compile(project, callback, run_config)
    if
        compiler_process.active_watcher(project)
        or compiler_process.active_process(project)
        or compiler_process.stopping_process(project)
    then
        log.add(
            "info",
            compiler_process.active_watcher(project)
                    and "stopping watcher before compile"
                or "restarting compile",
            {
                main = project.main,
            }
        )

        local restart = restart_handle.new()
        local stop_handle = M.stop(project, function(result)
            if restart.result ~= nil or restart.cancel_requested then
                return
            end
            if compiler_result.stop_allows_restart(result) then
                restart:set_next_handle(
                    compiler_compile.start(
                        project,
                        wrap_restart_callback(restart, callback),
                        run_config
                    )
                )
            elseif callback then
                restart:finish(result)
                callback(result)
            else
                restart:finish(result)
            end
        end)
        restart:set_stop_handle(stop_handle)
        return restart
    end

    return compiler_compile.start(project, callback, run_config)
end

--- Start or restart the built-in `typst watch` process for a project.
---@param project table Project state whose watcher slot is used.
---@param callback? fun(result:TypstCompilerResult) Watch-cycle or terminal callback.
---@param run_config? table Effective run configuration for this invocation.
---@return unknown handle Watcher or stop handle for the active transition.
function M.start(project, callback, run_config)
    if compiler_process.active_watcher(project) then
        local watcher = (compiler_service.get(project) or {}).watcher
        if not watcher then
            return compiler_watcher.start(project, callback, run_config)
        end
        local restart = restart_handle.new()
        -- Collapse repeated watcher restarts while SIGTERM is in flight; the
        -- latest run_config wins instead of launching parallel watch processes.
        compiler_process.queue_watcher_restart(
            watcher,
            wrap_restart_callback(restart, callback),
            run_config,
            restart
        )

        if watcher.stopping then
            log.add(
                "info",
                "watcher restart already pending",
                { main = project.main }
            )
            return restart:set_stop_handle(watcher.handle)
        end

        log.add("info", "restarting watcher", { main = project.main })
        local stop_handle = M.stop(project, function(result)
            local pending = watcher.restart_pending
            watcher.restart_pending = nil

            if
                pending
                and pending.restart_handle
                and (
                    pending.restart_handle.result ~= nil
                    or pending.restart_handle.cancel_requested
                )
            then
                return
            end
            if pending and compiler_result.stop_allows_restart(result) then
                local next_handle =
                    M.start(project, pending.callback, pending.run_config)
                if pending.restart_handle then
                    pending.restart_handle:set_next_handle(next_handle)
                end
            elseif pending and pending.callback then
                pending.callback(result)
            else
                restart:finish(result)
            end
        end)
        return restart:set_stop_handle(stop_handle)
    end

    if
        compiler_process.active_process(project)
        or compiler_process.stopping_process(project)
    then
        log.add(
            "info",
            "stopping compile before starting watcher",
            { main = project.main }
        )
        local restart = restart_handle.new()
        local stop_handle = M.stop(project, function(result)
            if restart.result ~= nil or restart.cancel_requested then
                return
            end
            if compiler_result.stop_allows_restart(result) then
                restart:set_next_handle(
                    M.start(
                        project,
                        wrap_restart_callback(restart, callback),
                        run_config
                    )
                )
            elseif callback then
                restart:finish(result)
                callback(result)
            else
                restart:finish(result)
            end
        end)
        return restart:set_stop_handle(stop_handle)
    end

    return compiler_watcher.start(project, callback, run_config)
end

--- Stop the active built-in compile or watcher for a project.
---@param project table Project state whose built-in process should stop.
---@param callback? fun(result:TypstCompilerResult) Stop result callback.
---@return unknown handle Active process handle, or nil when the compiler was already idle.
function M.stop(project, callback)
    if compiler_process.stopping_process(project) then
        local stopping = (compiler_service.get(project) or {}).stopping_compile
        if not stopping then
            if callback then
                callback({
                    code = 0,
                    stale = false,
                    stopped = true,
                    idle = true,
                })
            end
            return nil
        end
        compiler_process.add_stop_callback(stopping, callback)
        return stopping.handle
    end

    if compiler_process.active_process(project) then
        local compiler_state = compiler_service.get(project) or {}
        local handle = compiler_state.process
        local deps_path = compiler_state.active_compile_deps_path
        -- Bump generation before terminating so the old compile's exit callback
        -- cannot publish a result over a newer compile/watch request.
        compiler_service.set(project, {
            generation = (compiler_state.generation or 0) + 1,
            status = "stopping",
        })
        log.add("info", "stopping compile", { main = project.main })
        local ok, err, kill_timer = compiler_process.terminate_handle(
            handle,
            "compile process",
            { main = project.main }
        )

        if not ok then
            log.add("error", "failed to stop compile", { error = err })
            compiler_service.set(project, { status = "error" })
            if callback then
                callback({
                    code = 1,
                    error = err,
                    stale = false,
                    stopped = false,
                })
            end
            return handle
        end

        local stopping = {
            handle = handle,
            deps_path = deps_path,
            callbacks = {},
            kill_timer = kill_timer,
            finished = false,
        }
        compiler_process.add_stop_callback(stopping, callback)
        compiler_service.set(project, { stopping_compile = stopping })
        return handle
    end

    if not compiler_process.active_watcher(project) then
        compiler_service.set(project, {
            clear = { "watcher", "process" },
            status = "idle",
        })
        if callback then
            callback({ code = 0, stale = false, stopped = true, idle = true })
        end
        return nil
    end

    local compiler_state = compiler_service.get(project) or {}
    local watcher = compiler_state.watcher
    if not watcher then
        compiler_service.set(project, {
            clear = { "watcher", "process" },
            status = "idle",
        })
        if callback then
            callback({ code = 0, stale = false, stopped = true, idle = true })
        end
        return nil
    end
    if watcher.stopping then
        compiler_process.add_watcher_stop_callback(watcher, callback)
        log.add("info", "watcher stop already pending", { main = project.main })
        return watcher.handle
    end

    compiler_service.set(project, { status = "stopping" })
    watcher.stopping = true
    compiler_process.add_watcher_stop_callback(watcher, callback)
    log.add("info", "stopping watcher", { main = project.main })
    local ok, err, kill_timer = compiler_process.terminate_handle(
        watcher.handle,
        "watcher process",
        { main = project.main }
    )

    if not ok then
        log.add("error", "failed to stop watcher", { error = err })
        watcher.stopping = false
        watcher.stop_callbacks = nil
        compiler_service.set(project, { status = "error" })
        if callback then
            callback({ code = 1, error = err, stale = false, stopped = false })
        end
    else
        watcher.kill_timer = kill_timer
    end

    return watcher.handle
end

--- Stop built-in compiler processes synchronously for exit cleanup.
---@param project table Project state whose compile/watch handles should be shut down.
---@param opts? table Shutdown options such as timeouts.
---@return TypstCompilerResult result Final shutdown result.
function M.stop_for_exit(project, opts)
    opts = vim.tbl_extend("force", {
        timeout_ms = 750,
        kill_timeout_ms = 750,
    }, opts or {})
    local attempted = false
    local stopped = true
    local ok = true

    local did_stop, stop_ok =
        compiler_process.stop_compile_for_exit(project, opts)
    if did_stop then
        attempted = true
        stopped = stopped and stop_ok
        ok = ok and stop_ok
    end

    did_stop, stop_ok = compiler_process.stop_watcher_for_exit(project, opts)
    if did_stop then
        attempted = true
        stopped = stopped and stop_ok
        ok = ok and stop_ok
    end

    if not attempted then
        compiler_service.set(project, {
            clear = { "process", "watcher" },
            status = "idle",
        })
    end

    return {
        code = ok and 0 or 1,
        stale = false,
        stopped = stopped,
        idle = not attempted,
    }
end

--- Return the stored built-in compiler status for a project.
---@param project table Project state to query.
---@return string? status Compiler status stored in project services.
function M.status(project)
    return (compiler_service.get(project) or {}).status
end

--- Return the stored built-in compiler output path for a project.
---@param project table Project state to query.
---@return string? path Output file path stored in project services.
function M.output(project)
    return (compiler_service.get(project) or {}).output
end

return M
