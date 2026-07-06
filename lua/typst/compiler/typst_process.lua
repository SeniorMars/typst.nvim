local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_events = require("typst.compiler.events")
local async = require("typst.core.async")
local log = require("typst.core.log")
local process = require("typst.core.process")
local compiler_service = require("typst.project.services.compiler")

local M = {}
local uv = vim.uv or vim.loop

local function compiler_watch()
    return require("typst.compiler.watch")
end

-- Process-state helpers shared by one-shot compile and watch.
--
-- This module owns termination handshakes and stale-handle cleanup. Generation
-- and handle checks prevent late libuv callbacks from clearing newer jobs.
--- Check whether the project has an open built-in watcher handle.
---@param project TypstProject Project state whose compiler service is inspected.
---@return boolean|userdata|nil active Watcher handle when active, otherwise false/nil.
function M.active_watcher(project)
    local watcher = (compiler_service.get(project) or {}).watcher
    return watcher and watcher.handle and not watcher.handle:is_closing()
end

--- Check whether the project has an open one-shot compile handle.
---@param project TypstProject Project state whose compiler service is inspected.
---@return boolean|userdata|nil active Compile handle when active, otherwise false/nil.
function M.active_process(project)
    local handle = (compiler_service.get(project) or {}).process
    return handle and not handle:is_closing()
end

--- Check whether a one-shot compile is already in its stop transition.
---@param project TypstProject Project state whose compiler service is inspected.
---@return boolean|userdata|nil active Stopping handle when active, otherwise false/nil.
function M.stopping_process(project)
    local stopping = (compiler_service.get(project) or {}).stopping_compile
    return stopping and stopping.handle and not stopping.finished
end

local function active_handle(handle)
    return handle and not handle:is_closing()
end

--- Queue a watcher restart to run after the current compile process exits.
---@param watcher TypstCompilerWatcher Watcher state that owns the pending restart slot.
---@param callback function Compile callback to reuse when the restart starts.
---@param run_config? table Run configuration to pass to the restarted compile.
---@param restart_handle? table Restart proxy returned to the caller.
function M.queue_watcher_restart(watcher, callback, run_config, restart_handle)
    local previous = watcher.restart_pending
    if
        previous
        and previous.restart_handle
        and type(previous.restart_handle.finish) == "function"
    then
        previous.restart_handle:finish({
            ok = false,
            stale = true,
            stopped = true,
            reason = "superseded_restart",
        })
    end

    watcher.restart_pending = {
        callback = callback,
        run_config = run_config,
        restart_handle = restart_handle,
    }
end

--- Stop and close a libuv timer when it is still open.
---@param timer? any Timer handle created by `uv.new_timer`.
function M.close_timer(timer)
    async.close_timer(timer)
end

--- Request process termination with a SIGKILL fallback timer.
---@param handle any libuv process handle to terminate.
---@param label string Human-readable process label used in logs.
---@param fields? table Extra log fields.
---@return boolean ok True when SIGTERM or fallback signal was sent.
---@return any error Error object when the initial termination request failed.
---@return userdata? timer Fallback kill timer that must be closed when exit is observed.
function M.terminate_handle(handle, label, fields)
    fields = fields or {}
    -- Try graceful termination first so Typst can flush diagnostics/deps, but
    -- keep a SIGKILL timer so restarts are not blocked by a stuck child. On
    -- Windows this routes through taskkill /T so wrapper children are targeted
    -- during ordinary stop/restart, not only during reset/exit shutdown.
    local ok, err, mode, fallback = process.terminate_tree_signal(handle, 15)

    if not ok then
        return false, err
    end

    if fallback then
        log.add(
            "warn",
            label
                .. " process-group SIGTERM failed; fell back to direct process signal",
            vim.tbl_extend("force", fields, { error = fallback })
        )
    else
        log.add(
            "debug",
            label .. " SIGTERM sent",
            vim.tbl_extend("force", fields, { signal_target = mode })
        )
    end

    local timer = uv.new_timer()
    if not timer then
        return true, nil, nil
    end
    timer:start(
        1500,
        0,
        vim.schedule_wrap(function()
            M.close_timer(timer)
            if active_handle(handle) then
                local killed, kill_err, kill_mode, kill_fallback =
                    process.terminate_tree_signal(handle, 9)
                if killed then
                    log.add(
                        "warn",
                        label .. " did not stop after SIGTERM; sent SIGKILL",
                        vim.tbl_extend("force", fields, {
                            signal_target = kill_mode,
                            fallback_error = kill_fallback,
                        })
                    )
                else
                    log.add(
                        "warn",
                        label .. " SIGKILL failed",
                        vim.tbl_extend("force", fields, { error = kill_err })
                    )
                end
            end
        end)
    )
    return true, nil, timer
end

--- Add a callback to an in-flight compile stop transition.
---@param stopping TypstStoppingCompile Stopping compile record stored in project compiler state.
---@param callback? fun(result:TypstCompilerResult) Callback invoked when the stop settles.
function M.add_stop_callback(stopping, callback)
    if callback then
        stopping.callbacks[#stopping.callbacks + 1] = callback
    end
end

--- Add a callback to an in-flight watch stop transition.
---@param watcher TypstCompilerWatcher Watcher state stored in project compiler state.
---@param callback? fun(result:TypstCompilerResult) Callback invoked when the stop settles.
function M.add_watcher_stop_callback(watcher, callback)
    if type(callback) ~= "function" then
        return
    end
    watcher.stop_callbacks = watcher.stop_callbacks or {}
    watcher.stop_callbacks[#watcher.stop_callbacks + 1] = callback
end

local function protected_stop_callback(kind, callback, payload)
    local ok, err = pcall(callback, payload)
    if not ok then
        log.add("warn", kind .. " stop callback failed", {
            error = err,
        })
    end
end

--- Drain callbacks for a completed watcher stop exactly once.
---@param watcher TypstCompilerWatcher? Watcher state stored in project compiler state.
---@param payload TypstCompilerResult Stop result passed to each callback.
function M.drain_watcher_stop_callbacks(watcher, payload)
    local callbacks = watcher and watcher.stop_callbacks or {}
    if watcher then
        watcher.stop_callbacks = nil
    end

    for _, stop_callback in ipairs(callbacks) do
        protected_stop_callback("watcher", stop_callback, payload)
    end
end

--- Finish a pending one-shot compile stop if the exiting handle matches it.
---@param project TypstProject Project state whose stopping compile may be completed.
---@param handle userdata libuv process handle reported by the exit callback.
---@param result TypstCompilerResult Process result from the compile operation.
---@return boolean handled True when this exit completed the recorded stop transition.
function M.finish_stopped_compile(project, handle, result)
    local compiler_state = compiler_service.get(project) or {}
    local stopping = compiler_state.stopping_compile
    -- Only the recorded stopping handle may finish this transition; a newer
    -- compile can already be installed by the time libuv reports exit.
    if not stopping or stopping.handle ~= handle then
        return false
    end

    stopping.finished = true
    M.close_timer(stopping.kill_timer)
    compiler_dependencies.cleanup_file(stopping.deps_path)

    local fields = {
        clear = { "stopping_compile" },
        last_result = result,
        status = "idle",
    }
    if compiler_state.process == handle then
        fields.clear[#fields.clear + 1] = "process"
    else
        fields.process = compiler_state.process
    end
    if
        compiler_state.process_operation
        and compiler_state.process_operation.handle == handle
    then
        fields.clear[#fields.clear + 1] = "process_operation"
    else
        fields.process_operation = compiler_state.process_operation
    end
    if compiler_state.active_compile_deps_path == stopping.deps_path then
        fields.clear[#fields.clear + 1] = "active_compile_deps_path"
    else
        fields.active_compile_deps_path =
            compiler_state.active_compile_deps_path
    end
    compiler_service.set(project, fields)

    local payload = vim.tbl_extend("force", result or {}, {
        deps_path = stopping.deps_path,
        stale = false,
        stopped = true,
    })
    if stopping.exit_cleanup then
        log.add(
            "debug",
            "compile exit cleanup completed",
            { main = project.main, code = result and result.code }
        )
        return true
    end

    log.add(
        "info",
        "compile stopped",
        { main = project.main, code = result and result.code }
    )
    compiler_events.stopped(project, payload)

    for _, stop_callback in ipairs(stopping.callbacks) do
        protected_stop_callback("compile", stop_callback, payload)
    end

    return true
end

local function shutdown_result_code(ok, result)
    if ok and result and result.stopped ~= false then
        return 0
    end

    return 1
end

--- Synchronously stop a one-shot compile during exit cleanup.
---@param project TypstProject Project state whose compile handle should be stopped.
---@param opts table Shutdown options forwarded to the process helper.
---@return boolean attempted True when there was a compile handle to stop.
---@return boolean stopped True when no compile remains running.
function M.stop_compile_for_exit(project, opts)
    local compiler_state = compiler_service.get(project) or {}
    local stopping = compiler_state.stopping_compile
    local handle = stopping and stopping.handle or compiler_state.process
    if not handle then
        return false, true
    end

    -- VimLeavePre cannot rely on later scheduled callbacks, so exit cleanup is
    -- synchronous and releases dependency temp files here.
    local deps_path = stopping and stopping.deps_path
        or compiler_state.active_compile_deps_path
    compiler_service.set(project, {
        generation = (compiler_state.generation or 0) + 1,
        status = "stopping",
    })
    if stopping and stopping.handle == handle then
        M.close_timer(stopping.kill_timer)
        stopping.kill_timer = nil
        stopping.exit_cleanup = true
        stopping.deps_path = stopping.deps_path or deps_path
    else
        stopping = {
            handle = handle,
            deps_path = deps_path,
            callbacks = {},
            kill_timer = nil,
            finished = false,
            exit_cleanup = true,
        }
        compiler_service.set(project, { stopping_compile = stopping })
    end

    log.add("info", "stopping compile for exit", { main = project.main })
    local ok, result = process.shutdown(handle, opts)
    local stopped = ok and (not result or result.stopped ~= false)
    stopping.finished = stopped
    if stopped then
        compiler_dependencies.cleanup_file(stopping.deps_path)
    end

    local last_result = vim.tbl_extend("force", result or {}, {
        code = shutdown_result_code(ok, result),
        stale = false,
        stopped = stopped,
    })
    compiler_state = compiler_service.get(project) or compiler_state
    local fields = {
        clear = {},
        last_result = last_result,
        status = stopped and "idle" or "stopping_failed",
    }
    if stopped then
        fields.clear[#fields.clear + 1] = "stopping_compile"
        if compiler_state.process == handle then
            fields.clear[#fields.clear + 1] = "process"
        else
            fields.process = compiler_state.process
        end
        if
            compiler_state.process_operation
            and compiler_state.process_operation.handle == handle
        then
            fields.clear[#fields.clear + 1] = "process_operation"
        else
            fields.process_operation = compiler_state.process_operation
        end
        if compiler_state.active_compile_deps_path == stopping.deps_path then
            fields.clear[#fields.clear + 1] = "active_compile_deps_path"
        else
            fields.active_compile_deps_path =
                compiler_state.active_compile_deps_path
        end
    end
    compiler_service.set(project, fields)

    if stopped then
        log.add("info", "compile stopped for exit", {
            main = project.main,
            forced = result and result.forced,
            signal_target = result and result.signal_target,
        })
        compiler_events.stopped(project, last_result)
    else
        log.add("warn", "failed to stop compile during exit", {
            main = project.main,
            error = result and result.error,
        })
    end

    return true, stopped
end

--- Synchronously stop a watcher during exit cleanup.
---@param project TypstProject Project state whose watcher handle should be stopped.
---@param opts table Shutdown options forwarded to the process helper.
---@return boolean attempted True when there was a watcher handle to stop.
---@return boolean stopped True when no watcher remains running.
function M.stop_watcher_for_exit(project, opts)
    local compiler_state = compiler_service.get(project) or {}
    local watcher = compiler_state.watcher
    if not watcher then
        return false, true
    end

    compiler_service.set(project, {
        watch_generation = (compiler_state.watch_generation or 0) + 1,
        status = "stopping",
    })
    watcher.stopping = true
    watcher.exit_cleanup = true
    M.close_timer(watcher.kill_timer)
    watcher.kill_timer = nil
    compiler_watch().close_cycle_finish_timer(watcher.current_cycle)
    compiler_dependencies.stop_poll(watcher)

    log.add("info", "stopping watcher for exit", { main = project.main })
    local ok, result = process.shutdown(watcher.handle, opts)
    local stopped = ok and (not result or result.stopped ~= false)
    if stopped then
        compiler_dependencies.cleanup_file(watcher.deps_path)
    end

    compiler_state = compiler_service.get(project) or compiler_state
    local fields = {
        clear = {},
        status = stopped and "idle" or "stopping_failed",
    }
    if stopped then
        if compiler_state.watcher == watcher then
            fields.clear[#fields.clear + 1] = "watcher"
        else
            fields.watcher = compiler_state.watcher
        end
        if
            compiler_state.watcher_operation
            and compiler_state.watcher_operation.handle == watcher.handle
        then
            fields.clear[#fields.clear + 1] = "watcher_operation"
        else
            fields.watcher_operation = compiler_state.watcher_operation
        end
    end
    compiler_service.set(project, fields)

    if stopped then
        log.add("info", "watcher stopped for exit", {
            main = project.main,
            forced = result and result.forced,
            signal_target = result and result.signal_target,
        })
        compiler_events.stopped(project, {
            code = shutdown_result_code(ok, result),
            stale = false,
            stopped = stopped,
            forced = result and result.forced,
        })
    else
        log.add("warn", "failed to stop watcher during exit", {
            main = project.main,
            error = result and result.error,
        })
    end

    return true, stopped
end

return M
