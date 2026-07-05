local config = require("typst.config")
local diagnostics = require("typst.diagnostics")
local grammar_command = require("typst.syntax.grammar_command")
local grammar_output = require("typst.syntax.grammar_output")
local project_context = require("typst.project.context")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function resolve_project(bufnr, opts)
    if opts.project then
        return opts.project
    end

    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

local function diagnostic_total(by_buffer)
    local count = 0
    for _, buffer_diagnostics in pairs(by_buffer or {}) do
        count = count + #buffer_diagnostics
    end
    return count
end

local function maybe_open_quickfix(state, by_buffer, opts)
    if not opts.open then
        return {}
    end

    local items = diagnostics.set_quickfix(state, by_buffer)
    if #items > 0 then
        vim.cmd("copen")
    end
    return items
end

local function unavailable(message, fields)
    return vim.tbl_extend("force", {
        ok = false,
        reason = "unavailable",
        message = message,
    }, fields or {})
end

local function start_generation(state)
    state.grammar_generation = (state.grammar_generation or 0) + 1
    return state.grammar_generation
end

local function generation_stale(state, opts)
    local generation = opts and opts.grammar_generation
    return generation ~= nil
        and state
        and state.grammar_generation ~= generation
end

local function stale_result(opts, fields)
    return vim.tbl_extend(
        "force",
        {
            ok = false,
            stale = true,
            reason = "stale_result",
            message = "A newer grammar request finished first",
        },
        fields or {},
        {
            generation = opts and opts.grammar_generation,
        }
    )
end

local function publish_output(state, output, opts, fields)
    if generation_stale(state, opts) then
        return stale_result(opts, fields)
    end

    local output_fields = fields or {}
    output = grammar_output.normalize(output or "", {
        provider = output_fields.provider,
        parser = output_fields.parser,
        default_file = output_fields.default_file
            or opts.current_file
            or state.main,
    })
    local by_buffer, publish_err
    if output == "" then
        diagnostics.clear(state, { source = "typst grammar" })
        by_buffer = {}
    else
        by_buffer, publish_err =
            diagnostics.publish(state, output, { source = "typst grammar" })
        if not by_buffer then
            return vim.tbl_extend("force", {
                ok = false,
                reason = publish_err and publish_err.reason
                    or "diagnostics_publish_failed",
                message = publish_err and publish_err.message
                    or "Typst grammar diagnostics could not be published",
                error = publish_err,
                diagnostics = 0,
                buffers = 0,
                by_buffer = {},
                quickfix = {},
            }, output_fields)
        end
    end

    local items = maybe_open_quickfix(state, by_buffer, opts)
    local count = diagnostic_total(by_buffer)
    return vim.tbl_extend("force", {
        ok = true,
        diagnostics = count,
        buffers = vim.tbl_count(by_buffer),
        by_buffer = by_buffer,
        quickfix = items,
    }, output_fields)
end

local function publish_by_buffer(state, by_buffer, opts, fields)
    if generation_stale(state, opts) then
        return stale_result(opts, fields)
    end

    local published, items = diagnostics.publish_by_buffer(
        state,
        by_buffer or {},
        { source = "typst grammar" }
    )
    if opts.open and #items == 0 then
        items = diagnostics.set_quickfix(state, published)
    end
    if opts.open and #items > 0 then
        vim.cmd("copen")
    end
    local count = diagnostic_total(published)
    return vim.tbl_extend("force", {
        ok = true,
        diagnostics = count,
        buffers = vim.tbl_count(published),
        by_buffer = published,
        quickfix = items,
        published = true,
    }, fields or {})
end

local function normalize_provider_result(state, result, opts, provider_name)
    if generation_stale(state, opts) then
        return stale_result(opts, { provider = provider_name })
    end

    if type(result) == "string" then
        result = { output = result }
    end

    if type(result) ~= "table" then
        return {
            ok = false,
            reason = "invalid_result",
            provider = provider_name,
            message = "Grammar provider returned no result",
        }
    end

    if result.output ~= nil or result.text ~= nil then
        return publish_output(state, result.output or result.text, opts, {
            provider = result.provider or provider_name,
            parser = result.parser or result.provider or provider_name,
            default_file = result.default_file or opts.current_file,
            code = result.code,
        })
    end

    result.provider = result.provider or provider_name
    if result.by_buffer and result.published ~= true then
        local published = publish_by_buffer(state, result.by_buffer, opts, {
            provider = result.provider,
            code = result.code,
        })
        result = vim.tbl_extend("force", result, {
            diagnostics = published.diagnostics,
            buffers = published.buffers,
            by_buffer = published.by_buffer,
            quickfix = published.quickfix,
            published = true,
        })
    end
    if result.diagnostics == nil and result.by_buffer then
        result.diagnostics = diagnostic_total(result.by_buffer)
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
    callback
)
    local provider_state = providers.project_context(state)
    return provider_adapter.invoke(
        provider_config,
        { "grammar", "check", "run" },
        provider_state,
        opts,
        {
            kind = "grammar",
            provider_name = type(provider_config) == "table"
                    and provider_config.name
                or "callback",
            args = { bufnr, provider_state, opts },
            timeout_ms = opts.timeout_ms
                or config.unsafe_get().grammar.timeout_ms,
            on_result = callback,
            normalize = function(result, provider_name)
                return normalize_provider_result(
                    state,
                    result,
                    opts,
                    provider_name
                )
            end,
            invalid_result_message = "Grammar provider returned no result",
        }
    )
end

function M.check(opts, callback)
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

    local current_file = vim.api.nvim_buf_get_name(bufnr)
    local run_opts = vim.tbl_extend("force", opts, {
        current_file = opts.current_file
            or (current_file ~= "" and current_file or state.main),
        grammar_generation = start_generation(state),
    })
    local provider_config = providers.resolve(
        "grammar",
        run_opts.provider or config.unsafe_get().grammar.provider
    )
    if
        type(provider_config) == "function"
        or type(provider_config) == "table"
    then
        local result = run_custom_provider(
            provider_config,
            bufnr,
            state,
            run_opts,
            callback
        )
        return result
    end

    if
        provider_config == "command"
        or provider_config == "textidote"
        or provider_config == "vlty"
    then
        return grammar_command.run(
            provider_config,
            bufnr,
            state,
            run_opts,
            publish_output,
            unavailable,
            callback
        )
    end

    return unavailable(
        ("Unknown grammar provider: %s"):format(tostring(provider_config))
    )
end

M.grammar = M.check

return M
