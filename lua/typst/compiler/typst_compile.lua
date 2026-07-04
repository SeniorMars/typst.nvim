local config = require("typst.config")
local compiler_command = require("typst.compiler.command")
local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_fanout = require("typst.compiler.fanout")
local output_path_util = require("typst.compiler.output_path")
local compiler_process = require("typst.compiler.typst_process")
local compiler_events = require("typst.compiler.events")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_ownership = require("typst.resources.outputs")
local compiler_service = require("typst.project.services.compiler")
local scratch_policy = require("typst.compiler.scratch_policy")

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
    local supported, result = scratch_policy.check(project, "compile", opts)
    if not supported then
        compiler_service.set(project, {
            generation = generation,
            status = "error",
            last_result = result,
        })
        compiler_fanout.compile_failed(project, result, {
            publish_diagnostics = false,
        })
        if callback then
            callback(result)
        end
        return nil
    end

    local output = output_path_util.output_path(project, opts)
    local lease, lease_err = output_ownership.acquire(output, {
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
        compiler_fanout.compile_failed(project, result, {
            publish_diagnostics = false,
        })
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
        compiler_fanout.compile_failed(project, result, {
            publish_diagnostics = false,
        })
        if callback then
            callback(result)
        end
        return nil
    end

    local build_ok, command, deps_path = xpcall(function()
        return compiler_command.build("compile", project, opts)
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
        compiler_fanout.compile_failed(project, result, {
            publish_diagnostics = false,
        })
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
                output_ownership.release(lease)
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
                    compiler_service.set(project, {
                        clear = {
                            "process",
                            "process_operation",
                            "active_compile_deps_path",
                        },
                        last_result = final_result,
                        status = "success",
                    })
                    compiler_fanout.compile_succeeded(project, final_result, {
                        output = output,
                        generation = generation,
                        deps_path = deps_path,
                    })
                else
                    final_result.reason = final_result.reason
                        or "compile_failed"
                    final_result.message = final_result.message
                        or "Typst compile failed"
                    compiler_service.set(project, {
                        clear = {
                            "process",
                            "process_operation",
                            "active_compile_deps_path",
                        },
                        last_result = final_result,
                        status = "error",
                    })
                    compiler_fanout.compile_failed(project, final_result, {
                        deps_path = deps_path,
                    })
                end

                if callback then
                    callback(final_result)
                end
            end,
        })
    end, debug.traceback)
    if not run_ok then
        output_ownership.release(lease)
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
        compiler_fanout.compile_failed(project, result, {
            publish_diagnostics = false,
            cleanup_deps = false,
        })
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
