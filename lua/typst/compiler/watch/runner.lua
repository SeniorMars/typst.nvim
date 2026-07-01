local config = require("typst.config")
local compiler_command = require("typst.compiler.command")
local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_events = require("typst.compiler.events")
local compiler_output = require("typst.compiler.output")
local output_path_util = require("typst.compiler.output_path")
local compiler_watch = require("typst.compiler.watch.state")
local compiler_process = require("typst.compiler.typst_process")
local diagnostics = require("typst.diagnostics")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_ownership = require("typst.resources.outputs")
local compiler_service = require("typst.project.services.compiler")

local M = {}

-- Starts and finalizes `typst watch` jobs.
--
-- Watch output is parsed as compile cycles while the process stays alive. The
-- final exit path distinguishes "stopped", "exited after cycles", and "never
-- produced a cycle" so diagnostics and status remain accurate.
---@param watcher TypstCompilerWatcher? Watcher state that may own timers.
local function close_watcher_timers(watcher)
    if not watcher then
        return
    end

    compiler_process.close_timer(watcher.kill_timer)
    watcher.kill_timer = nil
    compiler_watch.close_cycle_finish_timer(watcher.current_cycle)
end

---@param project TypstProject Project that owned the stale watcher.
---@param watcher TypstCompilerWatcher? Stale watcher state.
---@param deps_path string? Dependency temp path to clean.
---@param result TypstCompilerResult Process exit result.
---@param callback? fun(result:TypstCompilerResult)
local function finish_stale_watcher(
    project,
    watcher,
    deps_path,
    result,
    callback
)
    -- Stale watchers still own dependency temp files and poll timers; clean
    -- them up even though their result must not update compiler state.
    log.add(
        "debug",
        "ignored stale watcher result",
        { generation = watcher and watcher.generation }
    )
    close_watcher_timers(watcher)
    compiler_dependencies.stop_poll(watcher)
    compiler_dependencies.cleanup_file(deps_path)
    if callback and not (watcher and watcher.exit_cleanup) then
        callback(vim.tbl_extend("force", result, { stale = true }))
    end
end

---@param project TypstProject Project whose watcher stopped.
---@param watcher TypstCompilerWatcher Watcher state.
---@param result TypstCompilerResult Process exit result.
---@param payload TypstCompilerResult Callback/event payload.
local function finish_stopping_watcher(project, watcher, result, payload)
    close_watcher_timers(watcher)
    compiler_service.set(project, { status = "idle" })
    compiler_dependencies.update_project(
        project,
        compiler_dependencies.take(watcher and watcher.deps_path, project.root)
    )
    log.add("info", "watch stopped", { code = result.code })
    compiler_events.stopped(project, payload)
    compiler_process.drain_watcher_stop_callbacks(watcher, payload)
end

---@param project TypstProject Project whose watcher exited.
---@param watcher TypstCompilerWatcher Watcher state.
---@param deps_path string? Dependency temp path.
---@param result TypstCompilerResult Process exit result.
local function finish_watcher_with_cycles(project, watcher, deps_path, result)
    if result.code == 0 then
        compiler_service.set(project, {
            status = "idle",
        })
        compiler_dependencies.update_project(
            project,
            compiler_dependencies.take(
                watcher and watcher.deps_path,
                project.root
            )
        )
        log.add(
            "info",
            "watch exited after compile cycles",
            { code = result.code }
        )
    else
        compiler_dependencies.cleanup_file(deps_path)
        compiler_service.set(project, {
            last_result = result,
            status = "error",
        })
        log.add("error", "watch process exited after compile cycles", {
            code = result.code,
            stderr = result.stderr,
            stdout = result.stdout,
        })
    end
end

---@param project TypstProject Project whose watcher exited.
---@param deps_path string? Dependency temp path.
---@param result TypstCompilerResult Process exit result.
local function finish_watcher_without_cycles(project, deps_path, result)
    if result.code == 0 then
        local output = (compiler_service.get(project) or {}).output
        require("typst.workflows.artifacts").record_owned(project, {
            path = output,
            producer = "compile",
        })
        compiler_service.set(project, {
            last_result = result,
            status = "success",
        })
        diagnostics.clear(project)
        compiler_dependencies.update_project(
            project,
            compiler_dependencies.take(deps_path, project.root)
        )
        log.add("info", "watch exited", { code = result.code })
        compiler_events.succeeded(project, result)
        return
    end

    compiler_dependencies.cleanup_file(deps_path)
    compiler_service.set(project, {
        last_result = result,
        status = "error",
    })
    if diagnostics.should_publish(project) then
        diagnostics.publish(
            project,
            ("%s\n%s"):format(result.stderr or "", result.stdout or "")
        )
    else
        diagnostics.clear(project)
    end
    log.add("error", "watch failed", {
        code = result.code,
        stderr = result.stderr,
        stdout = result.stdout,
    })
    compiler_events.failed(project, result)
end

---@param project TypstProject Project whose watcher output is flushed.
---@param watcher TypstCompilerWatcher? Watcher state.
---@param result TypstCompilerResult Process exit result.
local function flush_watcher(project, watcher, result)
    if not watcher then
        return
    end

    compiler_watch.drain_stream_queue(project, watcher)
    for _, pending in ipairs(compiler_output.flush_lines(watcher)) do
        compiler_watch.handle_line(
            project,
            watcher,
            pending.stream,
            pending.text
        )
    end

    if
        not watcher.stopping
        and watcher.current_cycle
        and not watcher.current_cycle.finished
    then
        local pending_error = watcher.current_cycle.pending_error_reason
        compiler_watch.finish_cycle(
            project,
            watcher,
            pending_error and 1 or (result.code == 0 and 0 or 1),
            pending_error or "watch process exited"
        )
    end
end

---@param project TypstProject Project whose watcher is finishing.
---@param watcher TypstCompilerWatcher? Watcher state passed from operation.
---@param deps_path string? Dependency temp path.
---@param result TypstCompilerResult Process exit result.
---@param callback? fun(result:TypstCompilerResult)
local function finish_watcher(project, watcher, deps_path, result, callback)
    if
        not watcher
        or watcher.generation
            ~= (compiler_service.get(project) or {}).watch_generation
    then
        finish_stale_watcher(project, watcher, deps_path, result, callback)
        return
    end

    local active_watcher = (compiler_service.get(project) or {}).watcher
    local was_stopping = active_watcher and active_watcher.stopping
    -- Typst can exit with a partial final line. Flush before classifying the
    -- result because cycle state depends on that buffered output.
    flush_watcher(project, active_watcher, result)
    compiler_dependencies.refresh_watcher(project, active_watcher)
    compiler_dependencies.stop_poll(active_watcher)

    local payload = vim.tbl_extend("force", result, {
        deps_path = deps_path,
        stale = false,
        stopped = was_stopping,
    })
    local had_completed_cycle = active_watcher
        and active_watcher.last_cycle_id ~= nil
    local had_cycle = active_watcher
        and (
            (active_watcher.cycle or 0) > 0
            or active_watcher.last_cycle_id ~= nil
        )
    compiler_service.set(project, {
        clear = {
            "watcher",
            "watcher_operation",
        },
    })

    if was_stopping then
        if not had_completed_cycle then
            compiler_service.set(project, { last_result = result })
        end
        finish_stopping_watcher(project, active_watcher, result, payload)
    elseif had_cycle then
        finish_watcher_with_cycles(project, active_watcher, deps_path, result)
    else
        finish_watcher_without_cycles(project, deps_path, result)
    end

    if callback then
        callback(payload)
    end
end

--- Launch one built-in `typst watch` process for a project.
---@param project TypstProject Project state with root, main file, and compiler service state.
---@param callback? fun(result:TypstCompilerResult) Watch-cycle or terminal result callback.
---@param run_config? table Effective run configuration used to build the command.
---@return userdata? handle libuv process handle, or nil when startup fails before spawn.
function M.start(project, callback, run_config)
    local opts = run_config or config.unsafe_get()
    local compiler_state = compiler_service.get(project) or {}
    local generation = (compiler_state.watch_generation or 0) + 1
    local output = output_path_util.output_path(project, opts)
    -- Hold the output lease for the whole watch lifetime so compile/export or
    -- render jobs cannot write the same PDF while `typst watch` is active.
    local lease, lease_err = output_ownership.acquire(output, {
        kind = "watch",
        project_key = project.key,
        main = project.main,
        generation = generation,
    })
    if not lease then
        local result = {
            code = 1,
            stdout = "",
            stderr = lease_err.message,
            ok = false,
            reason = lease_err.reason,
            message = lease_err.message,
            active_output = lease_err.active_output or output,
            stale = false,
        }
        compiler_service.set(project, {
            watch_generation = generation,
            status = "error",
            output = output,
            last_result = result,
        })
        compiler_events.failed(project, result)
        if callback then
            callback(result)
        end
        return nil
    end
    compiler_service.set(project, {
        watch_generation = generation,
        status = "starting",
        output = output,
        last_profile = opts.compile.profile,
    })
    local parent_ok, parent_err = output_ownership.ensure_parent(output)
    if not parent_ok then
        output_ownership.release(lease)
        local result = {
            code = 1,
            stdout = "",
            stderr = tostring(parent_err),
            ok = false,
            reason = "parent_create_failed",
            message = tostring(parent_err),
            path = output,
            stale = false,
        }
        compiler_service.set(project, {
            status = "error",
            last_result = result,
        })
        compiler_events.failed(project, result)
        if callback then
            callback(result)
        end
        return nil
    end

    local build_ok, command, deps_path = xpcall(function()
        return compiler_command.build("watch", project, opts)
    end, debug.traceback)
    if not build_ok then
        output_ownership.release(lease)
        local result = {
            code = 1,
            stdout = "",
            stderr = tostring(command),
            ok = false,
            reason = "command_build_failed",
            message = tostring(command),
            path = output,
            stale = false,
        }
        compiler_service.set(project, {
            status = "error",
            last_result = result,
        })
        compiler_events.failed(project, result)
        if callback then
            callback(result)
        end
        return nil
    end
    compiler_service.set(project, {
        last_command = command,
        last_cwd = project.root,
    })

    log.add("info", "watch started", {
        command = command,
        cwd = project.root,
        profile = opts.compile.profile,
        root = project.root,
        main = project.main,
        output = output,
    })

    local watcher_state = {
        handle = nil,
        operation = nil,
        generation = generation,
        command = command,
        cwd = project.root,
        deps_path = deps_path,
        watch_output = opts.compile.watch_output or "auto",
        watch_output_wait_ms = opts.compile.watch_output_wait_ms,
        watch_structured_args = vim.deepcopy(
            opts.compile.watch_structured_args or {}
        ),
        stdout = "",
        stderr = "",
        line_buffers = {},
        cycle = 0,
        currently_compiling = false,
        last_cycle_status = nil,
        stopping = false,
        callback = callback,
    }
    local run_ok, watcher_operation = xpcall(function()
        return operation.run("compiler-typst-watch", command, {
            cwd = project.root,
            text = true,
            stdout = function(_, data)
                local watcher = watcher_state
                -- libuv stream callbacks cannot safely touch Neovim state directly.
                -- Queue raw chunks immediately so process exit can drain them before
                -- terminal classification even if scheduled parsing has not run.
                compiler_watch.enqueue_stream(project, watcher, "stdout", data)
            end,
            stderr = function(_, data)
                local watcher = watcher_state
                compiler_watch.enqueue_stream(project, watcher, "stderr", data)
            end,
        }, {
            cleanup = function()
                output_ownership.release(lease)
            end,
            on_finish = function(result)
                finish_watcher(
                    project,
                    watcher_state,
                    deps_path,
                    result,
                    callback
                )
            end,
        })
    end, debug.traceback)
    if not run_ok then
        output_ownership.release(lease)
        compiler_dependencies.cleanup_file(deps_path)
        local result = {
            code = 1,
            stdout = "",
            stderr = tostring(watcher_operation),
            ok = false,
            reason = "process_start_failed",
            message = tostring(watcher_operation),
            path = output,
            stale = false,
        }
        compiler_service.set(project, {
            clear = { "watcher", "watcher_operation" },
            status = "error",
            last_result = result,
        })
        compiler_events.failed(project, result)
        if callback then
            callback(result)
        end
        return nil
    end
    local handle = watcher_operation.handle

    watcher_state.handle = handle
    watcher_state.operation = watcher_operation
    compiler_service.set(project, {
        watcher = watcher_state,
        watcher_operation = watcher_operation,
        status = "watching",
    })
    compiler_dependencies.start_poll(project, watcher_state)

    return handle
end

return M
