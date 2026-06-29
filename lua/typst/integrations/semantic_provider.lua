local config = require("typst.config")
local providers = require("typst.integrations.providers")
local tinymist = require("typst.integrations.tinymist")

local M = {}

local function configured_provider()
    local integrations = (config.unsafe_get() or {}).integrations or {}
    local semantic = integrations.semantic or {}
    if semantic.provider == nil then
        return "tinymist"
    end
    return semantic.provider
end

--- Resolve a semantic provider config value through the provider registry.
---@param provider? any Provider name or inline provider. Defaults to config.
---@return any provider Resolved provider, "tinymist", or an unresolved string.
function M.resolve(provider)
    if provider == nil then
        provider = configured_provider()
    end
    return providers.resolve("semantic", provider)
end

--- Return a stable display name for a semantic provider implementation.
---@param provider? any Provider implementation or name. Defaults to config.
---@return string name Provider identifier used in status and diagnostics policy.
function M.provider_name(provider)
    provider = provider or M.resolve()
    if provider == nil then
        return "off"
    end
    if provider == "tinymist" then
        return "tinymist"
    end
    if type(provider) == "string" then
        return provider
    end
    if type(provider) == "function" then
        return "callback"
    end
    if type(provider) == "table" then
        return provider.name or provider.id or "semantic"
    end
    return "semantic"
end

local function provider_context(project)
    if type(project) ~= "table" then
        return nil
    end
    return providers.project_context(project)
end

local function provider_value(provider, key, project)
    if type(provider) ~= "table" then
        return nil
    end

    local value = provider[key]
    if type(value) ~= "function" then
        return value
    end

    local ok, result = pcall(value, provider_context(project))
    if ok then
        return result
    end
    return nil
end

--- Return the active semantic provider name.
---@return string name Provider identifier used in status and diagnostics policy.
function M.name()
    return M.provider_name(M.resolve())
end

--- Report whether coc.nvim appears to own the Typst semantic session.
---@return boolean active True when coc.nvim/coc-tinymist is active.
function M.coc_active()
    local provider = M.resolve()
    local custom = provider_value(provider, "coc_active")
    if custom ~= nil then
        return custom == true
    end

    if provider == "tinymist" then
        return tinymist.coc_active()
    end
    return false
end

--- Report whether semantic provider integration is enabled.
---@param project? table Project state for project-scoped providers.
---@return boolean enabled True when integration policy allows provider lookup.
function M.enabled(project)
    local provider = M.resolve()
    if provider == nil then
        return false
    end
    if provider == "tinymist" then
        return tinymist.lsp_enabled()
    end
    if type(provider) == "string" then
        return false
    end
    if type(provider) == "function" then
        return true
    end

    local enabled = provider_value(provider, "enabled", project)
    if enabled ~= nil then
        return enabled ~= false
    end
    return type(provider) == "table"
end

--- Report whether a semantic provider is attached for a project.
---@param project table Project state.
---@return boolean attached True when a provider can serve semantic requests.
function M.available_for_project(project)
    local provider = M.resolve()
    if provider == "tinymist" then
        return tinymist.available_for_project(project)
    end
    if not M.enabled(project) then
        return false
    end
    if type(provider) == "function" then
        return type(project) == "table"
    end
    if type(provider) ~= "table" then
        return false
    end

    local available = provider_value(provider, "available_for_project", project)
    if available ~= nil then
        return available == true
    end

    available = provider_value(provider, "available", project)
    if available ~= nil then
        return available == true
    end

    local capabilities = provider_value(provider, "capabilities", project)
    if type(capabilities) == "table" then
        if capabilities.attached ~= nil then
            return capabilities.attached == true
        end
        if capabilities.available ~= nil then
            return capabilities.available == true
        end
    end

    return type(project) == "table"
end

local function provider_capability(provider, project, keys)
    local capabilities = provider_value(provider, "capabilities", project)
    if type(capabilities) ~= "table" then
        return nil
    end

    for _, key in ipairs(keys) do
        if capabilities[key] ~= nil then
            return capabilities[key] == true
        end
    end
    return nil
end

--- Report whether the semantic provider explicitly owns diagnostics.
---
--- Tinymist owns diagnostics when native LSP or coc-tinymist is active.
--- Custom semantic providers must opt in with `owns_diagnostics = true`,
--- `diagnostics = true`, or a matching capability flag; availability alone
--- must not hide compiler fallback diagnostics.
---@param project? table Project state for project-scoped providers.
---@return boolean owns True when compiler fallback diagnostics should suppress.
function M.owns_diagnostics(project)
    local provider = M.resolve()
    if provider == "tinymist" then
        return tinymist.coc_active()
            or (type(project) == "table" and tinymist.available_for_project(
                project
            ))
            or false
    end
    if not M.enabled(project) then
        return false
    end

    local explicit = provider_value(provider, "owns_diagnostics", project)
    if explicit ~= nil then
        return explicit == true
    end

    explicit = provider_value(provider, "diagnostics", project)
    if explicit ~= nil then
        return explicit == true
    end

    explicit = provider_capability(provider, project, {
        "owns_diagnostics",
        "diagnostics",
    })
    if explicit ~= nil then
        return explicit
    end

    return false
end

local function custom_mode(project)
    local provider = M.resolve()
    if provider == "tinymist" then
        return nil
    end
    if type(provider) == "string" then
        return "missing"
    end
    if type(provider) == "function" then
        return "callback"
    end

    local mode = provider_value(provider, "mode", project)
    if type(mode) == "string" and mode ~= "" then
        return mode
    end
    return type(provider) == "table" and "provider" or nil
end

local function custom_backend(project)
    local provider = M.resolve()
    if provider == "tinymist" then
        return nil
    end
    if type(provider) == "string" then
        return "missing"
    end
    if type(provider) == "function" then
        return "callback"
    end

    local backend = provider_value(provider, "backend", project)
    if type(backend) == "string" and backend ~= "" then
        return backend
    end
    return type(provider) == "table" and "custom" or nil
end

--- Return provider mode from the active semantic backend.
---@param project? table Project state for project-scoped providers.
---@return string mode Backend mode such as auto, detect, start, or provider.
function M.mode(project)
    return custom_mode(project) or tinymist.lsp_mode()
end

--- Return backend transport for the active semantic provider.
---@param project? table Project state for project-scoped providers.
---@return string backend Backend label such as nvim_lsp or custom.
function M.backend(project)
    return custom_backend(project) or tinymist.lsp_backend()
end

--- Return registered semantic provider names in deterministic order.
---@return string[] names Registered custom semantic providers.
function M.registered_names()
    return providers.names("semantic")
end

-- Compatibility helpers for callers that only need Tinymist-backed labels.
function M.tinymist_available_for_project(project)
    return tinymist.available_for_project(project)
end

--- Return a snapshot used by status/reporting code.
---@param project? table Project state.
---@return table status Semantic provider status.
function M.status(project)
    return {
        name = M.name(),
        mode = M.mode(project),
        backend = M.backend(project),
        enabled = M.enabled(project),
        attached = project and M.available_for_project(project) or false,
        coc_active = M.coc_active(),
        owns_diagnostics = M.owns_diagnostics(project),
        registered = M.registered_names(),
    }
end

return M
