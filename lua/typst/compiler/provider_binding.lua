local config = require("typst.config")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local compiler_service = require("typst.project.services.compiler")

local M = {}

local required_methods = { "compile", "start", "stop", "status" }

local function typst_provider()
    return require("typst.compiler.typst")
end

local function generic_provider(kind)
    return require("typst.compiler.generic").create(kind)
end

local function validate(provider)
    if type(provider) ~= "table" then
        error("typst.nvim: compiler provider must be a table")
    end

    for _, name in ipairs(required_methods) do
        if type(provider[name]) ~= "function" then
            error(
                ("typst.nvim: compiler provider missing method %s"):format(name)
            )
        end
    end

    if provider.outputless ~= true and type(provider.output) ~= "function" then
        error("typst.nvim: compiler provider missing method output")
    end
    if
        provider.outputless ~= nil
        and type(provider.outputless) ~= "boolean"
    then
        error("typst.nvim: compiler provider outputless must be boolean or nil")
    end

    return provider
end

local function load_failure(provider_name, reason, err)
    local message = ("Compiler provider %q could not be loaded: %s"):format(
        tostring(provider_name),
        tostring(err or reason)
    )
    local result = {
        ok = false,
        code = 1,
        reason = reason,
        message = message,
        stderr = tostring(err or message),
        stale = false,
        provider = provider_name,
    }
    local provider = {
        name = tostring(provider_name),
        load_error = result,
    }

    function provider.compile(_, callback)
        if callback then
            callback(vim.deepcopy(result))
        end
        return vim.deepcopy(result)
    end

    function provider.start(_, callback)
        if callback then
            callback(vim.deepcopy(result))
        end
        return vim.deepcopy(result)
    end

    function provider.stop(_, callback)
        local stopped = vim.tbl_extend("force", vim.deepcopy(result), {
            stopped = true,
            reason = "provider_not_started",
        })
        if callback then
            callback(stopped)
        end
        return nil
    end

    function provider.status()
        return "error"
    end

    function provider.output()
        return nil
    end

    return provider
end

local function validate_or_failure(provider, provider_name, reason)
    local ok, result = pcall(validate, provider)
    if ok then
        return result
    end
    return load_failure(provider_name, reason or "provider_invalid", result)
end

---@param provider TypstCompileProvider
---@param builtin boolean
---@return string label Stable label for the provider selected for one run.
function M.label(provider, builtin)
    if builtin then
        return "typst"
    end
    if type(provider) == "table" then
        return provider.name or "table"
    end
    return config.provider_label()
end

--- Resolve the configured compile provider and its provenance flags.
---@return TypstCompileProvider provider Provider implementation selected from config.
---@return boolean builtin True when the built-in Typst provider is active.
---@return boolean external True when config selected a non-built-in provider.
function M.configured()
    local provider = config.unsafe_get().compile.provider
    if provider == nil or provider == "typst" then
        return typst_provider(), true, false
    end

    if provider == "generic" or provider == "task" then
        return generic_provider(provider), false, false
    end

    if type(provider) == "string" then
        local registered = providers.get("compiler", provider)
        if registered then
            return validate_or_failure(registered, provider, "provider_invalid"),
                false,
                true
        end

        local ok, loaded = pcall(require, provider)
        if not ok then
            return load_failure(provider, "provider_load_failed", loaded),
                false,
                true
        end
        return validate_or_failure(loaded, provider, "provider_invalid"),
            false,
            true
    end

    if type(provider) == "function" then
        local ok, loaded = pcall(provider)
        if not ok then
            return load_failure("callback", "provider_load_failed", loaded),
                false,
                true
        end
        return validate_or_failure(loaded, "callback", "provider_invalid"),
            false,
            true
    end

    -- Normal setup validates inline table providers strictly before this point.
    -- Keep a structured fallback here for dynamic config mutation, registered
    -- providers, and tests that exercise corrupted runtime state.
    return validate_or_failure(
        provider,
        type(provider) == "table" and provider.name or "table",
        "provider_invalid"
    ),
        false,
        true
end

--- Attach the active compiler provider binding to a project.
---@param project TypstProject Project state mutated with the provider binding.
---@param provider TypstCompileProvider Provider selected for the active run.
---@param builtin boolean True when the provider is the built-in Typst backend.
---@param external boolean True when the provider needs an adapter project context.
function M.bind(project, provider, builtin, external)
    local label = M.label(provider, builtin)
    project.compiler_provider = {
        provider = provider,
        builtin = builtin,
        external = external == true,
        label = label,
    }
    compiler_service.set(project, {
        provider_label = label,
        provider_builtin = builtin == true,
        provider_external = external == true,
        last_provider_label = label,
    })
end

--- Return the provider that should handle the project's current compiler state.
---@param project TypstProject Project state whose active binding is inspected.
---@return TypstCompileProvider provider Active or newly configured provider.
---@return boolean builtin True when the provider is the built-in Typst backend.
---@return boolean external True when the provider needs an adapter project context.
function M.active(project)
    -- Active compiler work keeps its original provider even if setup() later
    -- changes config. Stop callbacks, output ownership, and event payloads must
    -- describe the provider that owns the process/watcher being resolved.
    local binding = project.compiler_provider
    local compiler_state = compiler_service.get(project) or {}
    if
        binding
        and (
            compiler_state.watcher
            or compiler_state.process
            or compiler_state.stopping_compile
        )
    then
        return binding.provider, binding.builtin, binding.external
    end

    return M.configured()
end

--- Clear the sticky provider binding once no compiler operation is active.
---@param project TypstProject Project state whose binding may be removed.
function M.clear_if_idle(project)
    local compiler_state = compiler_service.get(project) or {}
    if
        not compiler_state.watcher
        and not compiler_state.process
        and not compiler_state.stopping_compile
    then
        project.compiler_provider = nil
        compiler_service.set(project, {
            clear = {
                "provider_label",
                "provider_builtin",
                "provider_external",
            },
        })
    end
end

--- Check whether the project has an active compiler operation.
---@param project TypstProject Project state whose compiler service is inspected.
---@return unknown active Active process/watcher/stopping record, or nil when idle.
function M.has_active_operation(project)
    local compiler_state = compiler_service.get(project) or {}
    return compiler_state.watcher
        or compiler_state.process
        or compiler_state.stopping_compile
end

--- Return the project argument shape expected by the active provider.
---@param project TypstProject Internal project state.
---@param external boolean True when provider adapters should receive context objects.
---@param opts? table Context options forwarded to provider project construction.
---@return table project_arg Internal project or external-provider context.
function M.project_arg(project, external, opts)
    if external then
        return providers.project_context(project, opts)
    end
    return project
end

--- Copy provider context command/cwd reports back onto internal project state.
---@param project TypstProject Internal project state to update.
---@param context table Provider context returned to an external adapter.
function M.apply_context_reports(project, context)
    if context == project or type(context) ~= "table" then
        return
    end

    local context_compiler = context.services and context.services.compiler
        or {}
    local last_command = context.last_command or context_compiler.last_command
    local last_cwd = context.last_cwd or context_compiler.last_cwd

    if type(last_command) == "table" then
        compiler_service.set(project, {
            last_command = vim.deepcopy(last_command),
        })
    end
    if type(last_cwd) == "string" and last_cwd ~= "" then
        compiler_service.set(project, { last_cwd = last_cwd })
    end
end

--- Ask the provider for its output path and store it on project compiler state.
---@param provider TypstCompileProvider Active compiler provider.
---@param project TypstProject Project state whose compiler output may be updated.
---@param run_config? table Effective run configuration for the provider call.
function M.refresh_output(provider, project, run_config)
    if type(provider) == "table" and provider.outputless == true then
        compiler_service.set(project, {
            clear = { "output" },
            outputless = true,
        })
        return
    end
    compiler_service.set(project, {
        clear = { "output", "outputless" },
    })

    local binding = project.compiler_provider or {}
    local provider_project = M.project_arg(project, binding.external)
    local output = provider_adapter.invoke(
        provider,
        "output",
        provider_project,
        run_config,
        {
            kind = "compiler",
            provider_name = type(provider) == "table" and provider.name
                or "compiler",
            args = { provider_project, run_config },
            async = false,
            invalid_result_message = "Compiler output provider returned no result",
        }
    )
    if type(output) == "string" and output ~= "" then
        compiler_service.set(project, { output = output })
    end
end

return M
