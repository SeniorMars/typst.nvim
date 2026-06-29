local path_leases = require("typst.core.path_leases")
local process = require("typst.core.process")
local lifecycle = require("typst.compiler.lifecycle")
local compiler_service = require("typst.project.services.compiler")
local provider_binding = require("typst.compiler.provider_binding")
local provider_adapter = require("typst.integrations.provider_adapter")
local compiler_result = require("typst.compiler.state_machine")
local util = require("typst.core.util")

local M = {}

---@class TypstCompilerResult
---@field code integer? Process/operation exit code when available.
---@field stdout string?
---@field stderr string?
---@field stale boolean? Result was superseded by a newer run and should not be emitted.
---@field stopped boolean? Operation reached a stop transition.
---@field idle boolean?
---@field ok boolean?
---@field reason string?
---@field message string?
---@field active_output string?
---@field deps_path string?

-- Provider-neutral compile/watch coordinator.
--
-- Built-in Typst jobs, user-supplied compiler providers, and command-style
-- providers all report through this module so project compiler state, events,
-- output leases, and restart behavior stay consistent.

local function replace_active(project, start_next, callback)
    if not provider_binding.has_active_operation(project) then
        return nil
    end

    return lifecycle.replace_active(function(done)
        return M.stop(project, done)
    end, start_next, callback)
end

local function provider_name(provider)
    return type(provider) == "table" and provider.name or "compiler"
end

local function provider_timeout_ms(run_config)
    local compile = (run_config or require("typst.config").get()).compile or {}
    return compile.provider_timeout_ms
end

local function release_output_lease(project)
    local compiler_state = compiler_service.get(project) or {}
    local lease = compiler_state.output_lease
    if lease then
        path_leases.release(lease)
        compiler_service.set(project, { clear = { "output_lease" } })
    end
end

local function acquire_output_lease(project, kind, callback)
    local output = (compiler_service.get(project) or {}).output
    if type(output) ~= "string" or output == "" then
        return true
    end

    local parent_ok, parent_err = util.ensure_parent(output)
    if not parent_ok then
        local result = {
            ok = false,
            code = 1,
            stdout = "",
            stderr = tostring(parent_err),
            reason = "parent_create_failed",
            message = tostring(parent_err),
            path = output,
            stale = false,
        }
        compiler_service.set(project, {
            status = "error",
            last_result = result,
        })
        provider_binding.clear_if_idle(project)
        if callback then
            callback(result)
        end
        return false, result
    end

    -- External providers may not share typst.nvim's project state, so use a
    -- lease on the rendered output path to prevent concurrent compilers from
    -- trampling the same PDF.
    local lease, err = path_leases.acquire(output, {
        kind = kind,
        project_key = project.key,
        main = project.main,
    })
    if lease then
        compiler_service.set(project, { output_lease = lease })
        return true
    end

    local result = {
        ok = false,
        code = 1,
        stdout = "",
        stderr = err.message,
        reason = err.reason,
        message = err.message,
        active_output = err.active_output or output,
        stale = false,
    }
    compiler_service.set(project, {
        status = "error",
        last_result = result,
    })
    provider_binding.clear_if_idle(project)
    if callback then
        callback(result)
    end
    return false, result
end

--- Start one compile through the active compiler provider for a project.
---@param project table Project state whose compiler service owns the run.
---@param callback? fun(result:TypstCompilerResult) Terminal result callback.
---@param run_config? table Effective run configuration for this invocation.
---@return unknown handle Provider-specific process/pending handle, or nil when startup fails synchronously.
function M.compile(project, callback, run_config)
    if provider_binding.has_active_operation(project) then
        local provider, builtin = provider_binding.active(project)
        if builtin then
            return provider.compile(project, callback, run_config)
        end

        return replace_active(project, function(next_callback)
            return M.compile(project, next_callback, run_config)
        end, callback)
    end

    local provider, builtin, external = provider_binding.configured()
    provider_binding.bind(project, provider, builtin, external)
    if builtin then
        return provider.compile(project, callback, run_config)
    end

    compiler_service.set(project, {
        status = "compiling",
        last_profile = run_config
                and run_config.compile
                and run_config.compile.profile
            or nil,
    })
    provider_binding.refresh_output(provider, project, run_config)
    if
        external
        and not acquire_output_lease(
            project,
            "compiler-provider-compile",
            callback
        )
    then
        return nil
    end

    return lifecycle.with_started_event(
        project,
        callback,
        function(wrapped)
            local provider_project =
                provider_binding.project_arg(project, external)
            local handle = provider_adapter.invoke(
                provider,
                "compile",
                provider_project,
                run_config,
                {
                    kind = "compiler",
                    provider_name = provider_name(provider),
                    args = { provider_project, run_config },
                    callback_position = 2,
                    on_result = wrapped,
                    return_mode = "handle",
                    timeout_ms = provider_timeout_ms(run_config),
                    normalize = compiler_result.normalize,
                    invalid_result_message = "Compiler provider returned no result",
                }
            )
            provider_binding.apply_context_reports(project, provider_project)
            return handle
        end,
        "compiling",
        {
            active_field = "process",
            on_terminal = function(result)
                if compiler_result.terminal(result) then
                    release_output_lease(project)
                end
            end,
            after_started = function(handle)
                local compiler_state = compiler_service.get(project) or {}
                if handle and not compiler_state.process then
                    compiler_service.set(project, { process = handle })
                end
            end,
        }
    )
end

--- Start the long-running watch provider for a project.
---@param project table Project state whose compiler service owns the watcher.
---@param callback? fun(result:TypstCompilerResult) Watch-cycle or terminal result callback.
---@param run_config? table Effective run configuration for this invocation.
---@return unknown handle Provider-specific watcher/pending handle, or nil when startup fails synchronously.
function M.start(project, callback, run_config)
    if provider_binding.has_active_operation(project) then
        local provider, builtin = provider_binding.active(project)
        if builtin then
            return provider.start(project, callback, run_config)
        end

        return replace_active(project, function(next_callback)
            return M.start(project, next_callback, run_config)
        end, callback)
    end

    local provider, builtin, external = provider_binding.configured()
    provider_binding.bind(project, provider, builtin, external)
    if builtin then
        return provider.start(project, callback, run_config)
    end

    compiler_service.set(project, {
        status = "starting",
        last_profile = run_config
                and run_config.compile
                and run_config.compile.profile
            or nil,
    })
    provider_binding.refresh_output(provider, project, run_config)
    if
        external
        and not acquire_output_lease(
            project,
            "compiler-provider-watch",
            callback
        )
    then
        return nil
    end

    return lifecycle.with_started_event(
        project,
        callback,
        function(wrapped)
            local provider_project =
                provider_binding.project_arg(project, external)
            local handle = provider_adapter.invoke(
                provider,
                "start",
                provider_project,
                run_config,
                {
                    kind = "compiler",
                    provider_name = provider_name(provider),
                    args = { provider_project, run_config },
                    callback_position = 2,
                    on_result = wrapped,
                    return_mode = "handle",
                    timeout_ms = provider_timeout_ms(run_config),
                    normalize = compiler_result.normalize,
                    invalid_result_message = "Compiler provider returned no result",
                }
            )
            provider_binding.apply_context_reports(project, provider_project)
            return handle
        end,
        "starting",
        {
            active_field = "watcher",
            on_terminal = function(result)
                if compiler_result.terminal(result) then
                    release_output_lease(project)
                end
            end,
            after_started = function(handle)
                local compiler_state = compiler_service.get(project) or {}
                if handle and not compiler_state.watcher then
                    compiler_service.set(project, { watcher = handle })
                end

                compiler_state = compiler_service.get(project) or {}
                if
                    compiler_state.watcher
                    and compiler_state.status == "starting"
                then
                    compiler_service.set(project, { status = "watching" })
                end
            end,
        }
    )
end

--- Stop the active compiler provider process for a project.
---@param project table Project state whose active compile or watcher should stop.
---@param callback? fun(result:TypstCompilerResult) Stop result callback.
---@return unknown handle Provider-specific stop handle, or nil when the project was already idle.
function M.stop(project, callback)
    local provider, builtin, external = provider_binding.active(project)
    if builtin then
        return provider.stop(project, callback)
    end

    local compiler_state = compiler_service.get(project) or {}
    if not compiler_state.watcher and not compiler_state.process then
        compiler_service.set(project, {
            clear = { "watcher", "process" },
            status = "idle",
        })
        if callback then
            callback({ code = 0, stale = false, stopped = true, idle = true })
        end
        return nil
    end

    local provider_project =
        provider_binding.project_arg(project, external, { runtime = true })
    return provider_adapter.invoke(provider, "stop", provider_project, nil, {
        kind = "compiler",
        provider_name = provider_name(provider),
        args = { provider_project },
        callback_position = 2,
        return_mode = "handle",
        timeout_ms = provider_timeout_ms(),
        normalize = compiler_result.normalize,
        on_result = function(result)
            result = compiler_result.normalize(result)
            if result.stopped or result.idle or result.reason == "timeout" then
                release_output_lease(project)
                compiler_service.set(project, {
                    clear = { "process", "watcher", "output_lease" },
                })
            end

            compiler_result.emit(project, result)
            provider_binding.clear_if_idle(project)
            if callback then
                callback(result)
            end
        end,
        invalid_result_message = "Compiler stop provider returned no result",
    })
end

local function active_provider_handle(project)
    local compiler_state = compiler_service.get(project) or {}
    local active = compiler_state.watcher or compiler_state.process
    if type(active) == "table" and active.handle then
        return active.handle, active
    end

    return active, active
end

--- Stop compiler work synchronously during Neovim exit cleanup.
---@param project table Project state whose compiler process should be shut down.
---@param opts? table Shutdown options forwarded to the provider or process helper.
---@return TypstCompilerResult result Final shutdown result.
function M.stop_for_exit(project, opts)
    local provider, builtin, external = provider_binding.active(project)
    if builtin then
        local result = provider.stop_for_exit(project, opts)
        provider_binding.clear_if_idle(project)
        return result
    end

    local compiler_state = compiler_service.get(project) or {}
    if not compiler_state.watcher and not compiler_state.process then
        compiler_service.set(project, {
            clear = { "watcher", "process" },
            status = "idle",
        })
        return { code = 0, stale = false, stopped = false, idle = true }
    end

    local result
    if type(provider.stop_for_exit) == "function" then
        local provider_project =
            provider_binding.project_arg(project, external, { runtime = true })
        result = provider_adapter.invoke(
            provider,
            "stop_for_exit",
            provider_project,
            opts,
            {
                kind = "compiler",
                provider_name = provider_name(provider),
                args = { provider_project, opts },
                async = false,
                normalize = compiler_result.normalize,
                invalid_result_message = "Compiler stop_for_exit provider returned no result",
            }
        )
    else
        local handle, active = active_provider_handle(project)
        if type(active) == "table" then
            active.stop_requested = true
        end

        local ok, shutdown = process.shutdown(handle, opts)
        result = {
            code = ok and 0 or 1,
            stale = false,
            stopped = ok and (not shutdown or shutdown.stopped ~= false),
            forced = shutdown and shutdown.forced,
            error = shutdown and shutdown.error,
        }
    end

    result = compiler_result.normalize(
        result or { code = 0, stale = false, stopped = true }
    )
    if result.stopped or result.idle then
        release_output_lease(project)
        compiler_service.set(project, {
            clear = { "process", "watcher", "output_lease" },
        })
    else
        compiler_service.set(project, { status = "stopping_failed" })
    end
    compiler_result.emit(project, result)
    provider_binding.clear_if_idle(project)
    return result
end

--- Return the active compiler status for a project.
---@param project table Project state to query.
---@return string? status Provider-reported status or stored project compiler status.
function M.status(project)
    local provider, _, external = provider_binding.active(project)
    local provider_project = provider_binding.project_arg(project, external)
    local result =
        provider_adapter.invoke(provider, "status", provider_project, nil, {
            kind = "compiler",
            provider_name = provider_name(provider),
            args = { provider_project },
            async = false,
            invalid_result_message = "Compiler status provider returned no result",
        })
    if type(result) == "string" then
        return result
    end
    return (compiler_service.get(project) or {}).status
end

--- Return the current compiler output path for a project.
---@param project table Project state to query.
---@return string? path Provider-reported output path or stored compiler output path.
function M.output(project)
    local provider, _, external = provider_binding.active(project)
    local provider_project = provider_binding.project_arg(project, external)
    local result =
        provider_adapter.invoke(provider, "output", provider_project, nil, {
            kind = "compiler",
            provider_name = provider_name(provider),
            args = { provider_project },
            async = false,
            invalid_result_message = "Compiler output provider returned no result",
        })
    if type(result) == "string" and result ~= "" then
        return result
    end
    return (compiler_service.get(project) or {}).output
end

return M
