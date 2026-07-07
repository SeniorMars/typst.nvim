local config = require("typst.config")
local diagnostic_tool = require("typst.diagnostics.tool_result")
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

local grammar_results = diagnostic_tool.new({
    source = "typst grammar",
    generation_field = "grammar_generation",
    stale_message = "A newer grammar request finished first",
    publish_failed_message = "Typst grammar diagnostics could not be published",
    invalid_result_message = "Grammar provider returned no result",
    normalize_output = function(output, fields, opts, state)
        return grammar_output.normalize(output or "", {
            provider = fields.provider,
            parser = fields.parser,
            default_file = fields.default_file
                or opts.current_file
                or state.main,
        })
    end,
    output_fields = function(result, provider_name, opts)
        return {
            provider = result.provider or provider_name,
            parser = result.parser or result.provider or provider_name,
            default_file = result.default_file or opts.current_file,
            code = result.code,
        }
    end,
})

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
                return grammar_results.normalize_provider_result(
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
            grammar_results.publish_output,
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
