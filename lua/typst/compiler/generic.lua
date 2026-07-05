local config = require("typst.config")
local compiler_output = require("typst.compiler.output")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_path_util = require("typst.compiler.output_path")
local output_ownership = require("typst.resources.outputs")
local process = require("typst.core.process")
local compiler_service = require("typst.project.services.compiler")
local util = require("typst.core.util")

local M = {}

local function release_lease(state)
    if state and state.lease then
        output_ownership.release(state.lease)
        state.lease = nil
    end
end

local function provider_config(kind, run_config)
    return (run_config or config.unsafe_get()).compile[kind] or {}
end

local function output_path(project, run_config, runner)
    if type(runner.output) == "function" then
        local output = runner.output(project, run_config)
        if type(output) == "string" and output ~= "" then
            return util.resolve_path(output, project.root)
        end
    elseif type(runner.output) == "string" and runner.output ~= "" then
        return util.resolve_path(runner.output, project.root)
    end

    return output_path_util.output_path(
        project,
        run_config or config.unsafe_get()
    )
end

local function context(project, run_config, kind)
    local output = (compiler_service.get(project) or {}).output
        or output_path(project, run_config, provider_config(kind, run_config))
    local compile = run_config and run_config.compile or {}
    local stdin_source = type(compile.stdin) == "string"
    local source = project.main
    if
        project.fragment
        and type(project.fragment.source_path) == "string"
        and project.fragment.source_path ~= ""
    then
        source = project.fragment.source_path
    end
    return {
        root = project.root,
        main = stdin_source and "-" or project.main,
        source = source,
        output = output,
        profile = compile.profile or "",
        provider = kind,
        stdin = stdin_source and "1" or "",
    }
end

local function replace_placeholders(value, ctx)
    return (
        value:gsub("{([%w_]+)}", function(key)
            return ctx[key] or ""
        end)
    )
end

local function render_command(command, ctx)
    if type(command) == "string" then
        return { replace_placeholders(command, ctx) }
    end

    return vim.tbl_map(function(arg)
        return replace_placeholders(arg, ctx)
    end, vim.deepcopy(command))
end

local function cwd(project, run_config, runner, ctx)
    if type(runner.cwd) == "function" then
        local value = runner.cwd(project, run_config)
        if type(value) == "string" and value ~= "" then
            return util.resolve_path(
                replace_placeholders(value, ctx),
                project.root
            )
        end
    elseif type(runner.cwd) == "string" and runner.cwd ~= "" then
        return util.resolve_path(
            replace_placeholders(runner.cwd, ctx),
            project.root
        )
    end

    return project.root
end

local function missing_command(kind, mode, callback)
    local message = ("typst.nvim: compile.%s.%s is not configured"):format(
        kind,
        mode
    )
    local result = {
        code = 1,
        stderr = message,
        stdout = "",
        stale = false,
    }
    log.add(
        "error",
        "generic compiler command missing",
        { provider = kind, mode = mode }
    )
    if callback then
        callback(result)
    end
    return nil
end

local function run(kind, mode, project, callback, run_config)
    run_config = run_config or config.unsafe_get()
    local runner = provider_config(kind, run_config)
    local command_template = runner[mode]
    if command_template == nil then
        return missing_command(kind, mode, callback)
    end

    local ctx = context(project, run_config, kind)
    local lease, lease_err = output_ownership.acquire(ctx.output, {
        kind = ("generic-%s-%s"):format(kind, mode),
        project_key = project.key,
        main = project.main,
    })
    if not lease then
        lease_err = lease_err
            or {
                reason = "lease_failed",
                message = "Failed to acquire output lease",
            }
        local result = {
            code = 1,
            stdout = "",
            stderr = lease_err.message,
            ok = false,
            reason = lease_err.reason,
            message = lease_err.message,
            active_output = lease_err.active_output or ctx.output,
            stale = false,
        }
        compiler_service.set(project, {
            output = ctx.output,
            status = "error",
            last_result = result,
        })
        if callback then
            callback(result)
        end
        return nil
    end
    compiler_service.set(project, { output = ctx.output })
    local parent_ok, parent_err = output_ownership.ensure_parent(ctx.output)
    if not parent_ok then
        output_ownership.release(lease)
        local result = {
            code = 1,
            stdout = "",
            stderr = tostring(parent_err),
            ok = false,
            reason = "parent_create_failed",
            message = tostring(parent_err),
            path = ctx.output,
            stale = false,
        }
        compiler_service.set(project, {
            status = "error",
            last_result = result,
        })
        if callback then
            callback(result)
        end
        return nil
    end

    local command = render_command(command_template, ctx)
    local command_cwd = cwd(project, run_config, runner, ctx)
    compiler_service.set(project, {
        last_command = command,
        last_cwd = command_cwd,
        last_profile = run_config.compile.profile,
    })
    log.add("info", "generic compiler command started", {
        provider = kind,
        mode = mode,
        command = command,
        cwd = command_cwd,
        root = project.root,
        main = project.main,
        output = ctx.output,
    })
    local state = {
        provider = kind,
        mode = mode,
        stop_requested = false,
        stop_callback = nil,
        stop_result_sent = false,
        process_exited = false,
        lease = lease,
        stdout = "",
        stderr = "",
    }

    local system_opts = { cwd = command_cwd, text = true }
    if
        mode == "compile"
        and run_config.compile
        and type(run_config.compile.stdin) == "string"
    then
        system_opts.stdin = run_config.compile.stdin
    end
    if mode == "watch" then
        system_opts.stdout = function(_, data)
            if data and data ~= "" then
                state.stdout =
                    compiler_output.append_bounded(state.stdout, data)
            end
        end
        system_opts.stderr = function(_, data)
            if data and data ~= "" then
                state.stderr =
                    compiler_output.append_bounded(state.stderr, data)
            end
        end
    end

    state.operation = operation.run(
        ("compiler-%s-%s"):format(kind, mode),
        command,
        system_opts,
        {
            cleanup = function()
                release_lease(state)
            end,
            on_finish = function(result)
                state.process_exited = true
                if mode == "watch" then
                    result.stdout = state.stdout
                    result.stderr = state.stderr
                end
                if state.stop_requested then
                    result.stopped = true
                end

                compiler_service.set(project, { last_result = result })
                log.add(
                    result.stopped and "info"
                        or (result.code == 0 and "info" or "error"),
                    result.stopped and "generic compiler command stopped"
                        or "generic compiler command finished",
                    {
                        provider = kind,
                        mode = mode,
                        code = result.code,
                        stdout = result.stdout,
                        stderr = result.stderr,
                    }
                )

                if callback then
                    callback(vim.tbl_extend("force", result, { stale = false }))
                end

                if state.stop_callback and not state.stop_result_sent then
                    state.stop_result_sent = true
                    state.stop_callback(vim.tbl_extend("force", result, {
                        stale = false,
                        stopped = true,
                    }))
                end
            end,
        }
    )
    state.handle = state.operation.handle

    return state
end

--- Create a command-backed compiler provider.
---@param kind string Provider kind used to resolve configured commands.
---@return TypstCompileProvider provider Provider implementing compile/watch/stop.
function M.create(kind)
    return {
        name = kind,
        compile = function(project, callback, run_config)
            return run(kind, "compile", project, callback, run_config)
        end,
        start = function(project, callback, run_config)
            return run(kind, "watch", project, callback, run_config)
        end,
        stop = function(project, callback)
            local compiler_state = compiler_service.get(project) or {}
            local active = compiler_state.watcher or compiler_state.process
            if not active then
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

            active.stop_requested = true
            active.stop_callback = callback
            local handle = active.handle or active
            local ok, result = process.shutdown(handle)
            local stopped = ok and (not result or result.stopped ~= false)
            if stopped then
                release_lease(active)
            end

            if callback and not active.stop_result_sent then
                active.stop_result_sent = true
                callback({
                    code = ok and 0 or 1,
                    stale = false,
                    stopped = stopped,
                    forced = result and result.forced,
                    error = result and result.error,
                })
            end
            return active
        end,
        stop_for_exit = function(project, opts)
            local compiler_state = compiler_service.get(project) or {}
            local active = compiler_state.watcher or compiler_state.process
            if not active then
                return { code = 0, stale = false, stopped = true, idle = true }
            end

            active.stop_requested = true
            local ok, result = process.shutdown(active.handle or active, opts)
            local stopped = ok and (not result or result.stopped ~= false)
            if stopped then
                release_lease(active)
            end
            return {
                code = ok and 0 or 1,
                stale = false,
                stopped = stopped,
                forced = result and result.forced,
                error = result and result.error,
            }
        end,
        status = function(project)
            return (compiler_service.get(project) or {}).status
        end,
        output = function(project, run_config)
            return output_path(
                project,
                run_config or config.unsafe_get(),
                provider_config(kind, run_config or config.unsafe_get())
            )
        end,
    }
end

return M
