local M = {}

local contract = require("typst.integrations.provider_contract")

local registry = {}
local generations = {}

local function normalize_kind(kind)
    return contract.normalize_kind(kind)
end

local function validate_name(name)
    if type(name) ~= "string" or name == "" then
        error("typst.nvim: provider name must be a non-empty string")
    end
end

--- Register a named provider for one integration kind.
---@param kind string Provider kind or alias such as `compile`, `preview`, or `index`.
---@param name string Stable provider name used by config and diagnostics.
---@param provider any Provider implementation stored without wrapping.
---@return any provider The registered provider value.
function M.register(kind, name, provider)
    kind = normalize_kind(kind)
    validate_name(name)

    if provider == nil then
        error("typst.nvim: provider must not be nil")
    end

    registry[kind] = registry[kind] or {}
    registry[kind][name] = provider
    generations[kind] = (generations[kind] or 0) + 1
    return provider
end

--- Remove a named provider from one integration kind.
---@param kind string Provider kind or alias.
---@param name string Provider name to remove.
---@return any provider Previously registered provider, if present.
function M.unregister(kind, name)
    kind = normalize_kind(kind)
    validate_name(name)

    local bucket = registry[kind]
    if not bucket then
        return nil
    end

    local provider = bucket[name]
    bucket[name] = nil
    if provider ~= nil then
        generations[kind] = (generations[kind] or 0) + 1
    end
    return provider
end

--- Return one registered provider by kind and name.
---@param kind string Provider kind or alias.
---@param name string|nil Provider name to look up.
---@return any provider Registered provider, or nil when absent.
function M.get(kind, name)
    kind = normalize_kind(kind)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local bucket = registry[kind]
    return bucket and bucket[name] or nil
end

function M.has(kind, name)
    return M.get(kind, name) ~= nil
end

--- Return registered provider names for one kind in deterministic order.
---@param kind string Provider kind or alias.
---@return string[] names Sorted provider names.
function M.names(kind)
    kind = normalize_kind(kind)
    local names = vim.tbl_keys(registry[kind] or {})
    table.sort(names)
    return names
end

--- Return the mutation generation for one provider kind.
---@param kind string Provider kind or alias.
---@return integer generation Incremented whenever providers for this kind change.
function M.generation(kind)
    kind = normalize_kind(kind)
    return generations[kind] or 0
end

--- Resolve a provider config value to a registered provider when possible.
---@param kind string Provider kind or alias.
---@param provider any Provider name or inline provider value.
---@return any provider Registered provider for string values, otherwise the input value.
function M.resolve(kind, provider)
    if type(provider) == "string" then
        return M.get(kind, provider) or provider
    end

    return provider
end

--- Build the provider-safe project snapshot passed to integrations.
---@param project table Project state to expose through the provider boundary.
---@param opts? table Snapshot options forwarded to `typst.project.context`.
---@return table context Provider-facing project context.
function M.project_context(project, opts)
    return require("typst.project.context").snapshot(project, opts)
end

return M
