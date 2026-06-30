local config = require("typst.config")
local compiler_command = require("typst.compiler.command")
local compiler_dependencies = require("typst.compiler.dependencies")
local output_path_util = require("typst.compiler.output_path")
local compiler_process = require("typst.compiler.typst_process")
local diagnostics = require("typst.diagnostics")
local compiler_events = require("typst.compiler.events")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local path_leases = require("typst.core.path_leases")
local compiler_service = require("typst.project.services.compiler")
local util = require("typst.core.util")

local M = {}

--- Launch one built-in `typst compile` process for a project.
---@param project TypstProject Project state with root, main file, and compiler service state.
---@param callback? fun(result:TypstCompilerResult) Terminal compile result callback.
---@param run_config? table Effective run configuration used to build the command.
---@return userdata? handle libuv process handle, or nil when startup fails before spawn.
function M.start(project, callback, run_config)
    local opts = run_config or config.unsafe_get()
    local compiler_state = compiler_service.get(project) or {}
    local generation = (compiler_state.generation or 0) + 1
    local output = output_path_util.output_path(project, opts)
    local lease, lease_err = path_leases.acquire(output, {
        kind = "compile",
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
            generation = generation,
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
        generation = generation,
        status = "compiling",
        output = output,
        last_profile = opts.compile.profile,
    })
    local parent_ok, parent_err = util.ensure_parent(output)
    if not parent_ok then
        path_leases.release(lease)
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
        return compiler_command.build("compile", project, opts)
    end, debug.traceback)
    if not build_ok then
        path_leases.release(lease)
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
        active_compile_deps_path = deps_path,
    })

    log.add("info", "compile started", {
        command = command,
        cwd = project.root,
        profile = opts.compile.profile,
        root = project.root,
        main = project.main,
        output = output,
    })

    local handle
    local compile_operation
    local process_opts = { cwd = project.root, text = true }
    if opts.compile and type(opts.compile.stdin) == "string" then
        process_opts.stdin = opts.compile.stdin
    end

    local run_ok, run_result = xpcall(function()
        return operation.run("compiler-typst-compile", command, process_opts, {
            cleanup = function()
                path_leases.release(lease)
            end,
            on_finish = function(result)
                if
                    compiler_process.finish_stopped_compile(
                        project,
                        handle,
                        result
                    )
                then
                    return
                end

                if
                    generation
                    ~= (compiler_service.get(project) or {}).generation
                then
                    log.add(
                        "debug",
                        "ignored stale compile result",
                        { generation = generation }
                    )
                    compiler_dependencies.cleanup_file(deps_path)
                    if callback then
                        callback(
                            vim.tbl_extend("force", result, { stale = true })
                        )
                    end
                    return
                end

                local final_result = vim.tbl_extend("force", result, {
                    deps_path = deps_path,
                    stale = false,
                })

                if result.code == 0 then
                    require("typst.workflows.artifacts").record_owned(project, {
                        path = output,
                        producer = "compile",
                        generation = generation,
                    })
                    compiler_service.set(project, {
                        clear = {
                            "process",
                            "process_operation",
                            "active_compile_deps_path",
                        },
                        last_result = final_result,
                        status = "success",
                    })
                    diagnostics.clear(project)
                    compiler_dependencies.update_project(
                        project,
                        compiler_dependencies.take(deps_path, project.root)
                    )
                    log.add("info", "compile succeeded", { output = output })
                    compiler_events.succeeded(project, final_result)
                else
                    final_result.reason = final_result.reason
                        or "compile_failed"
                    final_result.message = final_result.message
                        or "Typst compile failed"
                    compiler_dependencies.cleanup_file(deps_path)
                    compiler_service.set(project, {
                        clear = {
                            "process",
                            "process_operation",
                            "active_compile_deps_path",
                        },
                        last_result = final_result,
                        status = "error",
                    })
                    if diagnostics.should_publish(project) then
                        diagnostics.publish(
                            project,
                            ("%s\n%s"):format(
                                result.stderr or "",
                                result.stdout or ""
                            )
                        )
                    else
                        diagnostics.clear(project)
                    end
                    log.add("error", "compile failed", {
                        code = result.code,
                        stderr = result.stderr,
                        stdout = result.stdout,
                    })
                    compiler_events.failed(project, final_result)
                end

                if callback then
                    callback(final_result)
                end
            end,
        })
    end, debug.traceback)
    if not run_ok then
        path_leases.release(lease)
        compiler_dependencies.cleanup_file(deps_path)
        local result = {
            code = 1,
            stdout = "",
            stderr = tostring(run_result),
            ok = false,
            reason = "process_start_failed",
            message = tostring(run_result),
            path = output,
            stale = false,
        }
        compiler_service.set(project, {
            clear = {
                "process",
                "process_operation",
                "active_compile_deps_path",
            },
            status = "error",
            last_result = result,
        })
        compiler_events.failed(project, result)
        if callback then
            callback(result)
        end
        return nil
    end
    compile_operation = run_result
    handle = compile_operation.handle

    compiler_service.set(project, {
        process = handle,
        process_operation = compile_operation,
    })
    compiler_events.started(project)
    return handle
end

return M
