local config = require("typst.config")
local async = require("typst.core.async")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_path_util = require("typst.compiler.output_path")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local reports = require("typst.ui.reports")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function provider_run(kind, project, opts, callback)
    local provider = providers.resolve(kind, opts.provider)
    if provider == nil or provider == "typst" then
        return nil
    end
    local provider_project = providers.project_context(project)
    local provider_callback = callback
        and function(result)
            callback(result, provider_project)
        end
    return provider_adapter.invoke(
        provider,
        { kind, "run" },
        provider_project,
        opts,
        {
            kind = kind,
            provider_name = type(provider) == "table" and provider.name
                or "callback",
            args = { provider_project, opts },
            callback_position = 3,
            timeout_ms = opts.timeout_ms or 10000,
            on_result = provider_callback,
            invalid_result_message = ("Typst %s provider returned no result"):format(
                kind
            ),
        }
    )
end

local function profile_paths(project, opts)
    local run_config = config.for_run(opts.profile, {})
    local output = output_path_util.output_path(project, run_config)
    local timings = opts.output
        or util.join(
            run_config.output_dir or config.default_output_dir(),
            ("%s.timings.json"):format(util.stem(project.main))
        )
    return output, util.resolve_path(timings, project.root), run_config
end

local function profile_command(project, output, timings, run_config, opts)
    local command =
        vim.list_extend(util.command_prefix(run_config.executable), {
            "compile",
            "--root",
            project.root,
            "--timings",
            timings,
        })

    for _, arg in ipairs(run_config.compile.extra_args or {}) do
        command[#command + 1] = arg
    end
    for _, arg in ipairs(opts.extra_args or {}) do
        command[#command + 1] = arg
    end

    command[#command + 1] = project.main
    command[#command + 1] = output
    return command
end

local function open_profile_report(result)
    local lines = {
        "typst.nvim profile",
        ("  main: %s"):format(result.main),
        ("  output: %s"):format(result.output),
        ("  timings: %s"):format(result.timings),
        ("  exit: %s"):format(vim.inspect(result.code)),
    }
    if result.stderr and result.stderr ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "stderr:"
        for _, line in ipairs(util.split_lines(result.stderr)) do
            lines[#lines + 1] = line
        end
    end
    return reports.open_scratch_buffer(
        "typst.nvim profile",
        "typstprofile",
        lines
    )
end

local function option_args(value)
    if value == nil or value == "" then
        return {}
    end
    if type(value) == "table" then
        return vim.deepcopy(value)
    end
    return vim.split(tostring(value), "%s+", { trimempty = true })
end

local function extend_args(command, values)
    for _, value in ipairs(values or {}) do
        command[#command + 1] = value
    end
end

local function default_tool_command(kind, project, opts)
    local executable = opts.executable or opts.command
    local command

    if kind == "bench" then
        executable = executable or "crityp"
        command = util.command_prefix(executable)
        if opts.subcommand then
            command[#command + 1] = opts.subcommand
        end
    else
        executable = executable or opts.tinymist or "tinymist"
        command = util.command_prefix(executable)
        command[#command + 1] = "test"
        command[#command + 1] = "--root"
        command[#command + 1] = project.root
        if kind == "coverage" then
            command[#command + 1] = "--coverage"
            if opts.full or opts.print_coverage == "full" then
                command[#command + 1] = "--print-coverage=full"
            elseif opts.print_coverage then
                command[#command + 1] = "--print-coverage="
                    .. tostring(opts.print_coverage)
            end
        end
    end

    extend_args(command, option_args(opts.args))
    extend_args(command, opts.extra_args)
    command[#command + 1] = opts.target or opts.main or project.main
    return command
end

local function command_available(command)
    local executable = util.command_executable(command)
    return type(executable) == "string"
        and executable ~= ""
        and vim.fn.executable(executable) == 1
end

local function open_development_report(result)
    local lines = {
        ("typst.nvim %s"):format(result.kind),
        ("  main: %s"):format(result.main),
        ("  provider: %s"):format(result.provider),
        ("  command: %s"):format(table.concat(result.command or {}, " ")),
        ("  exit: %s"):format(vim.inspect(result.code)),
    }
    if result.coverage then
        lines[#lines + 1] = ("  coverage: %s"):format(result.coverage)
    elseif result.coverage_expected then
        lines[#lines + 1] = "  coverage: <not reported by tool>"
        lines[#lines + 1] = ("  coverage expected: %s"):format(
            result.coverage_expected
        )
    end
    if result.stdout and result.stdout ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "stdout:"
        for _, line in ipairs(util.split_lines(result.stdout)) do
            lines[#lines + 1] = line
        end
    end
    if result.stderr and result.stderr ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "stderr:"
        for _, line in ipairs(util.split_lines(result.stderr)) do
            lines[#lines + 1] = line
        end
    end
    return reports.open_scratch_buffer(
        ("typst.nvim %s"):format(result.kind),
        "typstdev",
        lines
    )
end

--- Run a profiled Typst compile and optionally open the timings report.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Profile options.
---@param callback? fun(result:table, context?:table) Terminal profile result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.profile(project, opts, callback, notify)
    opts = opts or {}
    local provider_result = provider_run("profile", project, opts, callback)
    if provider_result ~= nil then
        return provider_result
    end

    local output, timings, run_config = profile_paths(project, opts)
    for _, path in ipairs({ output, timings }) do
        local parent_ok, parent_err = util.ensure_parent(path)
        if not parent_ok then
            return {
                ok = false,
                pending = false,
                reason = "parent_create_failed",
                message = tostring(parent_err),
                path = path,
            }
        end
    end
    local command = profile_command(project, output, timings, run_config, opts)
    local result = {
        ok = true,
        pending = true,
        main = project.main,
        output = output,
        timings = timings,
        command = command,
    }

    notify_user(notify, "Profiling Typst compile")
    operation.attach(result, "profile", command, {
        cwd = project.root,
        text = true,
        detach = false,
    }, {
        on_finish = function(exit)
            if async.cancelled(result) then
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0
            if opts.open ~= false then
                result.buffer = open_profile_report(result)
            end
            log.add(result.ok and "info" or "error", "typst profile finished", {
                code = exit.code,
                timings = timings,
            })
            notify_user(
                notify,
                result.ok and "Typst profile finished" or "Typst profile failed",
                result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
            if callback then
                callback(result, providers.project_context(project))
            end
        end,
    })

    return result
end

local function executable_unavailable(kind, command)
    return {
        ok = false,
        provider = nil,
        reason = "missing_executable",
        kind = kind,
        command = command,
        message = ("No executable was found for Typst %s"):format(kind),
    }
end

local function coverage_fallback_path(project, opts)
    if opts.output then
        return util.resolve_path(opts.output, project.root)
    end
    return util.resolve_path(
        util.join(
            util.coverage_output_dir(),
            util.project_id(project),
            "coverage.json"
        ),
        project.root
    )
end

local function reported_coverage_path(output)
    for _, line in ipairs(util.split_lines(output or "")) do
        local path = line:match("Written coverage to%s+(.+)$")
        if path then
            path = path:gsub("%s+%.%.%.$", "")
            path = vim.trim(path)
            if path ~= "" then
                return path
            end
        end
    end
    return nil
end

local function coverage_path(project, result, opts)
    local fallback = coverage_fallback_path(project, opts)
    if opts.output then
        if vim.fn.filereadable(fallback) == 1 then
            return fallback, nil
        end
        return nil, fallback
    end
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local path = reported_coverage_path(output)
    if path then
        return util.resolve_path(path, project.root), nil
    end
    if vim.fn.filereadable(fallback) == 1 then
        return fallback, nil
    end
    return nil, fallback
end

local function run_default_tool(kind, project, opts, callback, notify)
    local command = default_tool_command(kind, project, opts)
    if not command_available(command) then
        local result = executable_unavailable(kind, command)
        if opts.notify ~= false then
            notify_user(notify, result.message, vim.log.levels.WARN)
        end
        return result
    end

    local result = {
        ok = true,
        pending = true,
        provider = kind == "bench" and "crityp" or "tinymist",
        kind = kind,
        main = project.main,
        command = command,
    }

    notify_user(notify, ("Running Typst %s"):format(kind))
    local proc_opts = {
        cwd = project.root,
        text = true,
        detach = false,
    }
    if opts.env then
        proc_opts.env = opts.env
    end
    operation.attach(result, kind, command, proc_opts, {
        on_finish = function(exit)
            if async.cancelled(result) then
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0
            if kind == "coverage" then
                local coverage, expected = coverage_path(project, result, opts)
                result.coverage = coverage
                result.coverage_expected = expected
            end
            if opts.open ~= false then
                result.buffer = open_development_report(result)
            end
            log.add(
                result.ok and "info" or "error",
                "typst development command finished",
                {
                    kind = kind,
                    provider = result.provider,
                    code = exit.code,
                }
            )
            notify_user(
                notify,
                result.ok and ("Typst %s finished"):format(kind)
                    or ("Typst %s failed"):format(kind),
                result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
            if callback then
                callback(result, providers.project_context(project))
            end
        end,
    })

    return result
end

--- Run the configured Typst test workflow.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Test options.
---@param callback? fun(result:table, context?:table) Terminal test result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.test(project, opts, callback, notify)
    opts = opts or {}
    local result = provider_run("test", project, opts, callback)
    if result ~= nil then
        if opts.notify ~= false then
            notify_user(notify, "Typst test provider finished")
        end
        return result
    end
    return run_default_tool("test", project, opts, callback, notify)
end

--- Run the configured Typst benchmark workflow.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Benchmark options.
---@param callback? fun(result:table, context?:table) Terminal benchmark result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.bench(project, opts, callback, notify)
    opts = opts or {}
    local result = provider_run("bench", project, opts, callback)
    if result ~= nil then
        if opts.notify ~= false then
            notify_user(notify, "Typst bench provider finished")
        end
        return result
    end
    return run_default_tool("bench", project, opts, callback, notify)
end

--- Run the configured Typst coverage workflow.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Coverage options.
---@param callback? fun(result:table, context?:table) Terminal coverage result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.coverage(project, opts, callback, notify)
    opts = opts or {}
    local result = provider_run("coverage", project, opts, callback)
    if result ~= nil then
        if opts.notify ~= false then
            notify_user(notify, "Typst coverage provider finished")
        end
        return result
    end
    return run_default_tool("coverage", project, opts, callback, notify)
end

return M
