local config = require("typst.config")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local util = require("typst.core.util")

local M = {}

local provider_commands = {
    textidote = "textidote",
    vlty = "vlty",
}

local function buffer_text(bufnr)
    local text =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if vim.bo[bufnr].endofline then
        text = text .. "\n"
    end
    return text
end

local function command_output(result)
    if result.stderr and result.stderr ~= "" then
        return result.stderr
    end
    return result.stdout or ""
end

local function expand_arg(arg, context)
    local expanded = arg:gsub("{file}", function()
        return context.file
    end)
    expanded = expanded:gsub("{main}", function()
        return context.main
    end)
    expanded = expanded:gsub("{root}", function()
        return context.root
    end)
    return expanded
end

local function expand_args(args, context)
    return vim.tbl_map(function(arg)
        return expand_arg(arg, context)
    end, args or {})
end

local function has_file_placeholder(args)
    for _, arg in ipairs(args or {}) do
        if arg:find("{file}", 1, true) or arg:find("{main}", 1, true) then
            return true
        end
    end
    return false
end

local function append_args(command, args)
    local full = util.command_prefix(command)
    for _, arg in ipairs(args or {}) do
        full[#full + 1] = arg
    end
    return full
end

local function provider_command(provider_name, grammar_config, opts)
    if opts.command ~= nil then
        return opts.command
    end
    if grammar_config.command ~= nil then
        return grammar_config.command
    end
    return provider_commands[provider_name]
end

local function provider_uses_stdin(provider_name, grammar_config, opts)
    if opts.stdin ~= nil then
        return opts.stdin
    end
    if grammar_config.stdin ~= nil then
        return grammar_config.stdin
    end
    return provider_name == "command"
end

local function provider_uses_file_arg(provider_name, grammar_config, opts)
    if opts.file_arg ~= nil then
        return opts.file_arg
    end
    if grammar_config.file_arg ~= nil then
        return grammar_config.file_arg
    end
    return provider_name == "textidote" or provider_name == "vlty"
end

local function system_result(result, timeout_ms)
    if result and result.spawn_failed then
        return nil, result.error or result.stderr, "spawn_failed"
    end
    if
        not result
        or result.reason == "timeout"
        or result.timeout_reached
        or result.code == 124
    then
        return nil,
            ("command timed out after %dms"):format(timeout_ms or 0),
            "timeout"
    end
    if result.cancelled then
        return nil, "command was cancelled", "cancelled"
    end

    return result, nil
end

local function run_system(command, opts, stdin, callback)
    local system_opts = {
        cwd = opts.cwd,
        text = true,
        detach = false,
    }
    if stdin ~= nil then
        system_opts.stdin = stdin
    end

    local reported = false
    local function report(finished)
        if reported then
            return
        end
        reported = true
        local result, err, reason = system_result(finished, opts.timeout_ms)
        if callback then
            callback(result, err, reason, finished)
        end
    end

    local pending = operation.run("grammar", command, system_opts, {
        timeout_ms = opts.timeout_ms,
        on_cancel_failed = report,
    })
    pending.command = command

    pending:on_finish(report)
    return pending
end

local function finish_result(
    provider_name,
    state,
    opts,
    context,
    full_command,
    publish_output,
    result,
    err,
    reason
)
    if not result then
        return {
            ok = false,
            reason = reason or "spawn_failed",
            provider = provider_name,
            command = full_command,
            message = err,
        }
    end

    local output_text = command_output(result)
    if output_text == "" and result.code ~= 0 then
        return {
            ok = false,
            reason = "command_failed",
            provider = provider_name,
            command = full_command,
            code = result.code,
            message = "Grammar command failed without diagnostics",
        }
    end

    return publish_output(state, output_text, opts, {
        provider = provider_name,
        parser = provider_name,
        default_file = context.file,
        command = full_command,
        code = result.code,
        output = output_text,
    })
end

function M.run(
    provider_name,
    bufnr,
    state,
    opts,
    publish_output,
    unavailable,
    callback
)
    local grammar_config = config.unsafe_get().grammar
    local command = provider_command(provider_name, grammar_config, opts)
    if command == nil then
        return unavailable(
            "No grammar command is configured",
            { provider = provider_name }
        )
    end

    local executable = util.command_executable(command)
    if vim.fn.executable(executable) ~= 1 then
        return unavailable(
            ("Grammar executable not found: %s"):format(executable),
            {
                provider = provider_name,
                command = command,
            }
        )
    end

    local buffer_name = vim.api.nvim_buf_get_name(bufnr)
    local context = {
        file = buffer_name ~= "" and buffer_name or state.main,
        main = state.main,
        root = state.root,
    }
    local args = expand_args(grammar_config.extra_args or {}, context)
    vim.list_extend(args, expand_args(opts.extra_args or {}, context))

    if
        provider_uses_file_arg(provider_name, grammar_config, opts)
        and not has_file_placeholder(args)
    then
        args[#args + 1] = context.file
    end

    local full_command = append_args(command, args)
    log.add("info", "grammar provider started", {
        provider = provider_name,
        command = full_command,
        cwd = state.root,
        main = state.main,
    })
    local stdin = nil
    if provider_uses_stdin(provider_name, grammar_config, opts) then
        stdin = buffer_text(bufnr)
    end

    local result = run_system(
        full_command,
        {
            cwd = state.root,
            timeout_ms = opts.timeout_ms or grammar_config.timeout_ms,
        },
        stdin,
        function(done, done_err, done_reason, pending)
            local final = finish_result(
                provider_name,
                state,
                opts,
                context,
                full_command,
                publish_output,
                done,
                done_err,
                done_reason
            )
            for key, value in pairs(final) do
                pending[key] = value
            end
            if callback then
                callback(pending)
            end
        end
    )

    result.provider = provider_name
    result.parser = provider_name
    return result
end

return M
