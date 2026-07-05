local config = require("typst.config")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local project_context = require("typst.project.context")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local results = require("typst.lint.results")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

-- Lint provider orchestration.
--
-- Providers can be external commands, Typst itself, Tinymist diagnostics, or a
-- user callback. Async providers all publish through generation-tagged results
-- so an older lint run cannot clear diagnostics from a newer one.
local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

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

local function command_output(result)
    if result.stderr and result.stderr ~= "" then
        return result.stderr
    end
    return result.stdout or ""
end

local function append_args(command, args)
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

local function start_generation(state)
    -- Lint results carry this generation through completion; results.lua drops
    -- stale output instead of replacing diagnostics after a slower provider wins
    -- the race.
    state.lint_generation = (state.lint_generation or 0) + 1
    return state.lint_generation
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

    local pending = operation.run("lint", command, system_opts, {
        timeout_ms = opts.timeout_ms,
        on_cancel_failed = report,
    })
    pending.command = command

    pending:on_finish(report)
    return pending
end

local function finish_typst(state, opts, command, output, result, err, reason)
    local deleted, delete_err = util.delete_checked(output)
    if not deleted and vim.fn.filereadable(output) == 1 then
        log.add(
            "warn",
            "failed to delete temporary Typst lint output",
            { path = output, error = delete_err }
        )
    end

    if not result then
        return {
            ok = false,
            reason = reason or "spawn_failed",
            provider = "typst",
            command = command,
            message = err,
        }
    end

    if result.code == 0 then
        return results.publish_output(state, "", opts, {
            provider = "typst",
            command = command,
            code = result.code,
        })
    end

    local output_text = command_output(result)
    if output_text == "" then
        return {
            ok = false,
            reason = "command_failed",
            provider = "typst",
            command = command,
            code = result.code,
            message = "Typst lint failed without diagnostics",
        }
    end

    return results.publish_output(state, output_text, opts, {
        provider = "typst",
        command = command,
        code = result.code,
        output = output_text,
    })
end

local function run_typst(state, opts, callback)
    local cfg = config.unsafe_get()
    local lint_config = cfg.lint
    local output = vim.fn.tempname() .. "." .. (cfg.output_format or "pdf")
    -- Typst exposes compiler diagnostics through compile, not a standalone lint
    -- command. The temporary artifact is discarded after stderr/stdout has been
    -- normalized into Neovim diagnostics.
    local args = {
        "compile",
        "--root",
        state.root,
        "--diagnostic-format",
        "short",
    }
    vim.list_extend(args, lint_config.extra_args or {})
    vim.list_extend(args, opts.extra_args or {})
    args[#args + 1] = state.main
    args[#args + 1] = output

    local command = append_args(cfg.executable, args)
    log.add("info", "lint typst compile started", {
        command = command,
        cwd = state.root,
        main = state.main,
    })
    local run_opts = {
        cwd = state.root,
        timeout_ms = opts.timeout_ms or lint_config.timeout_ms,
    }
    local result = run_system(
        command,
        run_opts,
        nil,
        function(done, done_err, done_reason, pending)
            local final = finish_typst(
                state,
                opts,
                command,
                output,
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

    result.provider = "typst"
    return result
end

local function finish_command(state, opts, full_command, result, err, reason)
    if not result then
        return {
            ok = false,
            reason = reason or "spawn_failed",
            provider = "command",
            command = full_command,
            message = err,
        }
    end

    local output_text = command_output(result)
    if output_text == "" and result.code ~= 0 then
        return {
            ok = false,
            reason = "command_failed",
            provider = "command",
            command = full_command,
            code = result.code,
            message = "Lint command failed without diagnostics",
        }
    end

    return results.publish_output(state, output_text, opts, {
        provider = "command",
        command = full_command,
        code = result.code,
        output = output_text,
    })
end

local function run_command(bufnr, state, opts, callback)
    local lint_config = config.unsafe_get().lint
    local command = opts.command or lint_config.command
    if command == nil then
        return unavailable(
            "No lint command is configured",
            { provider = "command" }
        )
    end

    local executable = util.command_executable(command)
    if vim.fn.executable(executable) ~= 1 then
        return unavailable(
            ("Lint executable not found: %s"):format(executable),
            {
                provider = "command",
                command = command,
            }
        )
    end

    local args = vim.deepcopy(lint_config.extra_args or {})
    vim.list_extend(args, opts.extra_args or {})
    local full_command = append_args(command, args)
    local result = run_system(
        full_command,
        {
            cwd = state.root,
            timeout_ms = opts.timeout_ms or lint_config.timeout_ms,
        },
        buffer_text(bufnr),
        function(done, done_err, done_reason, pending)
            local final = finish_command(
                state,
                opts,
                full_command,
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

    result.provider = "command"
    return result
end

local function run_tinymist(state, opts)
    if not tinymist.available_for_project(state) then
        return unavailable(
            "Tinymist Neovim LSP client is not attached",
            { provider = "tinymist", reason = "no_client" }
        )
    end

    -- Tinymist already owns these diagnostics through Neovim's LSP namespace.
    -- The lint command snapshots them into typst.nvim's report/quickfix shape
    -- instead of issuing a second LSP request.
    local function tinymist_namespaces(bufnr)
        local namespaces = {}
        if not (vim.lsp and vim.lsp.diagnostic) then
            return namespaces
        end

        for _, client in ipairs(tinymist.clients(bufnr)) do
            if
                client.id
                and type(vim.lsp.diagnostic.get_namespace) == "function"
            then
                local ok, namespace =
                    pcall(vim.lsp.diagnostic.get_namespace, client.id)
                if ok and type(namespace) == "number" then
                    namespaces[#namespaces + 1] = namespace
                end
            end
        end
        return namespaces
    end

    local by_buffer = {}
    for bufnr in pairs(state.bufs or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local buffer_diagnostics = {}
            for _, namespace in ipairs(tinymist_namespaces(bufnr)) do
                vim.list_extend(
                    buffer_diagnostics,
                    vim.diagnostic.get(bufnr, { namespace = namespace })
                )
            end
            if #buffer_diagnostics > 0 then
                by_buffer[bufnr] = buffer_diagnostics
            end
        end
    end

    local items = results.maybe_open_quickfix(state, by_buffer, opts)
    return {
        ok = true,
        provider = "tinymist",
        diagnostics = results.diagnostic_total(by_buffer),
        buffers = vim.tbl_count(by_buffer),
        by_buffer = by_buffer,
        quickfix = items,
    }
end

local function run_custom_provider(
    provider_config,
    bufnr,
    state,
    opts,
    callback
)
    local provider_state = providers.project_context(state)
    return provider_adapter.invoke(
        provider_config,
        "lint",
        provider_state,
        opts,
        {
            kind = "lint",
            provider_name = type(provider_config) == "table"
                    and provider_config.name
                or "callback",
            args = { bufnr, provider_state, opts },
            timeout_ms = opts.timeout_ms or config.unsafe_get().lint.timeout_ms,
            on_result = callback,
            normalize = function(result, provider_name)
                return results.normalize_provider_result(
                    state,
                    result,
                    opts,
                    provider_name
                )
            end,
            invalid_result_message = "Lint provider returned no result",
        }
    )
end

function M.lint(opts, callback)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local state = resolve_project(bufnr, opts)
    if not state then
        return {
            ok = false,
            reason = "no_project",
            message = "No Typst project is attached to the current buffer",
        }
    end
    opts = vim.tbl_extend("force", opts, {
        lint_generation = start_generation(state),
    })
    local provider_config = providers.resolve(
        "lint",
        opts.provider or config.unsafe_get().lint.provider
    )
    if
        type(provider_config) == "function"
        or type(provider_config) == "table"
    then
        return run_custom_provider(
            provider_config,
            bufnr,
            state,
            opts,
            callback
        )
    end

    if provider_config == "tinymist" then
        local result = run_tinymist(state, opts)
        if callback then
            callback(result)
        end
        return result
    end

    if provider_config == "command" then
        return run_command(bufnr, state, opts, callback)
    end

    if provider_config == "typst" then
        return run_typst(state, opts, callback)
    end

    return unavailable(
        ("Unknown lint provider: %s"):format(tostring(provider_config))
    )
end

return M
