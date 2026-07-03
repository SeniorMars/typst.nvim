local config = require("typst.config")
local prose = require("typst.formatting.prose")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local project_context = require("typst.project.context")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

-- Formatting provider orchestration.
--
-- Formatters may answer synchronously, through vim.system, or through LSP. The
-- apply guard combines a per-buffer request generation with changedtick so late
-- formatter output never overwrites edits made after formatting started.
local M = {}
local normalize_provider_result
local format_generations = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.forget(bufnr)
    if bufnr == nil then
        format_generations = {}
        return true
    end
    format_generations[normalize_bufnr(bufnr)] = nil
    return true
end

function M.reset()
    return M.forget()
end

function M._generation(bufnr)
    return format_generations[normalize_bufnr(bufnr)] or 0
end

local function resolve_project(bufnr, opts)
    if opts.project then
        return opts.project
    end

    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

local function buffer_text(bufnr)
    local text =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if vim.bo[bufnr].endofline then
        text = text .. "\n"
    end
    return text
end

local function lines_from_text(text)
    text = text or ""
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end

    if text == "" then
        return { "" }
    end

    return vim.split(text, "\n", { plain = true })
end

local function apply_text(bufnr, text)
    local next_lines = lines_from_text(text)
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local changed = not vim.deep_equal(current_lines, next_lines)

    if changed then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, next_lines)
    end

    return changed
end

local function start_apply_context(bufnr, opts)
    -- Dry-run callers still want formatter output, but only requests that may
    -- write the buffer need a generation and changedtick guard.
    if opts and opts.apply == false then
        return nil
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local generation = (format_generations[bufnr] or 0) + 1
    format_generations[bufnr] = generation

    return {
        generation = generation,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    }
end

local function validate_apply_context(bufnr, apply_context, provider_name)
    -- Providers can complete after another format request or after the user
    -- edits the buffer. Treat that as a result, not an exception, so callers can
    -- surface a clear "stale" or "buffer_changed" reason.
    if not apply_context then
        return nil
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {
            ok = false,
            reason = "invalid_buffer",
            provider = provider_name,
            message = "Formatted buffer no longer exists",
        }
    end

    if format_generations[bufnr] ~= apply_context.generation then
        return {
            ok = false,
            reason = "stale_format",
            provider = provider_name,
            message = "A newer format request started",
        }
    end

    if vim.api.nvim_buf_get_changedtick(bufnr) ~= apply_context.changedtick then
        return {
            ok = false,
            reason = "buffer_changed",
            provider = provider_name,
            message = "Buffer changed while formatting",
        }
    end

    return nil
end

local function extend_command(command, args)
    local full = util.command_prefix(command)
    for _, arg in ipairs(args or {}) do
        full[#full + 1] = arg
    end
    return full
end

local function unavailable(message, fields)
    return vim.tbl_extend("force", {
        ok = false,
        reason = "unavailable",
        message = message,
    }, fields or {})
end

function normalize_provider_result(
    bufnr,
    result,
    opts,
    provider_name,
    apply_context
)
    opts = opts or {}

    if type(result) == "string" then
        result = { ok = true, text = result }
    end

    if type(result) ~= "table" then
        return {
            ok = false,
            reason = "invalid_result",
            provider = provider_name,
            message = "Formatter provider returned no result",
        }
    end

    result.provider = result.provider or provider_name

    if result.text ~= nil and opts.apply ~= false then
        local apply_error =
            validate_apply_context(bufnr, apply_context, provider_name)
        if apply_error then
            return vim.tbl_extend("force", result, apply_error)
        end
        result.changed = apply_text(bufnr, result.text)
    elseif result.changed == nil then
        result.changed = false
    end

    if result.ok == nil then
        result.ok = true
    end

    return result
end

local function run_custom_provider(
    provider_config,
    bufnr,
    state,
    opts,
    apply_context,
    callback
)
    local provider_state = providers.project_context(state)
    return provider_adapter.invoke(
        provider_config,
        "format",
        provider_state,
        opts,
        {
            kind = "format",
            provider_name = type(provider_config) == "table"
                    and provider_config.name
                or "callback",
            args = { bufnr, provider_state, opts },
            timeout_ms = opts.timeout_ms
                or config.unsafe_get().format.timeout_ms,
            on_result = callback,
            normalize = function(result, provider_name)
                return normalize_provider_result(
                    bufnr,
                    result,
                    opts,
                    provider_name,
                    apply_context
                )
            end,
            invalid_result_message = "Formatter provider returned no result",
        }
    )
end

local function normalize_command_exit(
    bufnr,
    result,
    opts,
    provider_name,
    full_command,
    timeout_ms
)
    if result and result.spawn_failed then
        return {
            ok = false,
            reason = "spawn_failed",
            provider = provider_name,
            message = result.error or result.stderr,
            command = full_command,
        }
    end

    if
        not result
        or result.reason == "timeout"
        or result.timeout_reached
        or result.code == 124
    then
        return {
            ok = false,
            reason = "timeout",
            provider = provider_name,
            command = full_command,
            message = ("Formatter command timed out after %dms"):format(
                timeout_ms or 0
            ),
        }
    end

    if result.cancelled then
        return {
            ok = false,
            reason = "cancelled",
            provider = provider_name,
            command = full_command,
            message = "Formatter command was cancelled",
        }
    end

    if result.code ~= 0 then
        return {
            ok = false,
            reason = "command_failed",
            provider = provider_name,
            command = full_command,
            code = result.code,
            stdout = result.stdout,
            stderr = result.stderr,
            message = result.stderr ~= "" and result.stderr
                or "Formatter command failed",
        }
    end

    if result.stdout == nil then
        return {
            ok = false,
            reason = "empty_output",
            provider = provider_name,
            command = full_command,
            message = "Formatter command produced no stdout",
        }
    end

    local input_text = opts.input_text
    local input_has_content = type(input_text) == "string"
        and input_text ~= ""
        and input_text ~= "\n"
    if result.stdout == "" and input_has_content then
        return {
            ok = false,
            reason = "empty_output",
            provider = provider_name,
            command = full_command,
            message = "Formatter command produced empty stdout; command formatters must write the full formatted file to stdout",
        }
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {
            ok = false,
            reason = "invalid_buffer",
            provider = provider_name,
            command = full_command,
            message = "Formatted buffer no longer exists",
        }
    end

    return normalize_provider_result(bufnr, {
        ok = true,
        provider = provider_name,
        text = result.stdout,
        command = full_command,
        code = result.code,
    }, opts, provider_name, opts.apply_context)
end

local function run_command(bufnr, state, opts, provider_name, callback)
    local format_config = config.unsafe_get().format
    local command = opts.command or format_config.command
    if command == nil then
        return unavailable(
            "No formatter command is configured",
            { provider = provider_name }
        )
    end

    local executable = util.command_executable(command)
    if vim.fn.executable(executable) ~= 1 then
        return unavailable(
            ("Formatter executable not found: %s"):format(executable),
            {
                provider = provider_name,
                command = command,
            }
        )
    end

    local args = vim.deepcopy(format_config.extra_args or {})
    vim.list_extend(args, opts.extra_args or {})
    local full_command = extend_command(command, args)
    local apply_context = start_apply_context(bufnr, opts)
    local input = buffer_text(bufnr)
    local cwd = state and state.root or vim.fn.getcwd()
    local timeout_ms = opts.timeout_ms or format_config.timeout_ms

    log.add("info", "format command started", {
        command = full_command,
        cwd = cwd,
        provider = provider_name,
    })

    local reported = false
    local function report(finished)
        if reported then
            return
        end
        reported = true
        local normalized = normalize_command_exit(
            bufnr,
            finished,
            vim.tbl_extend("force", opts, {
                apply_context = apply_context,
                input_text = input,
            }),
            provider_name,
            full_command,
            timeout_ms
        )
        for key, value in pairs(normalized) do
            finished[key] = value
        end
        if callback then
            callback(finished)
        end
    end

    local result = operation.run("format", full_command, {
        cwd = cwd,
        stdin = input,
        text = true,
        detach = false,
    }, {
        timeout_ms = timeout_ms,
        on_cancel_failed = report,
    })
    result.provider = provider_name
    result.command = full_command

    result:on_finish(report)

    return result
end

function M.format(opts, callback)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local state = resolve_project(bufnr, opts)
    local format_config = config.unsafe_get().format
    local provider_config = opts.provider or format_config.provider
    provider_config = providers.resolve("format", provider_config)

    if
        type(provider_config) == "function"
        or type(provider_config) == "table"
    then
        local apply_context = start_apply_context(bufnr, opts)
        local result = run_custom_provider(
            provider_config,
            bufnr,
            state,
            opts,
            apply_context,
            callback
        )
        return result
    end

    if provider_config == "tinymist" or provider_config == "auto" then
        -- "auto" prefers Tinymist because it formats through the active LSP
        -- project context; command-based formatters are fallback paths when LSP
        -- formatting is unavailable or declines.
        local apply_context = start_apply_context(bufnr, opts)
        local result = tinymist.format(
            bufnr,
            vim.tbl_extend("force", opts, {
                timeout_ms = opts.timeout_ms or format_config.timeout_ms,
                apply_guard = function()
                    return validate_apply_context(
                        bufnr,
                        apply_context,
                        "tinymist"
                    )
                end,
            }),
            callback
        )
        if type(result) == "table" and result.pending then
            return result
        end
        if result.ok or provider_config == "tinymist" then
            if callback then
                callback(result)
            end
            return result
        end
    end

    if
        provider_config == "typstyle"
        or provider_config == "command"
        or provider_config == "auto"
    then
        local provider_name = provider_config == "command" and "command"
            or "typstyle"
        return run_command(bufnr, state, opts, provider_name, callback)
    end

    if provider_config == "prose" then
        local apply_context = start_apply_context(bufnr, opts)
        local result = normalize_provider_result(
            bufnr,
            prose.run(bufnr, opts),
            opts,
            "prose",
            apply_context
        )
        if callback then
            callback(result)
        end
        return result
    end

    return unavailable(
        ("Unknown formatter provider: %s"):format(tostring(provider_config))
    )
end

M.apply_text = apply_text
M.buffer_text = buffer_text
M.prose_format_text = prose.format_text

return M
