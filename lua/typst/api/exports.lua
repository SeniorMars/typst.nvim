local api_spec = require("typst.api.spec")

local M = {}

---@class TypstApiNamespaceSpec
---@field name string
---@field source table|nil
---@field methods table<string, string|table>

---@class TypstApiGlobalSpec
---@field name string
---@field module string
---@field method string
---@field args string|nil

-- Builds the public typst.nvim Lua API from a declarative spec.
--
-- Most entries stay lazy so setup does not pull in compiler, project-index, or
-- UI modules until a command actually needs them.
local function lazy(module_name, method)
    return function(...)
        return require(module_name)[method](...)
    end
end

--- Create a lazy method dispatcher for a generated API namespace.
---@param source table Namespace source module and factory method metadata.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification callback passed into namespace factories.
---@return fun(method:string):fun(...):any dispatcher Function that resolves one exported method on demand.
local function method_cache(source, notify)
    -- Factory namespaces capture injected helpers like notify. Cache one facade
    -- per namespace so repeated API calls share that state without eager loads.
    local methods = nil
    return function(method)
        return function(...)
            if not methods then
                methods = require(source.module)[source.method or "create"]({
                    notify = notify,
                })
            end
            return methods[method](...)
        end
    end
end

local function normalize_method_map(methods)
    local normalized = {}
    for key, value in pairs(methods or {}) do
        if type(key) == "number" then
            normalized[value] = value
        else
            normalized[key] = value
        end
    end
    return normalized
end

local custom_methods = {}

function custom_methods.bibliography_diagnostics_namespace(opts)
    local bibliography = require("typst.bibliography")
    if type(opts) == "table" then
        if opts.root then
            return bibliography.diagnostics_namespace_for(opts)
        end
        return bibliography.diagnostics_namespace_for(opts.project)
    end
    if type(opts) == "number" then
        return bibliography.diagnostics_namespace_for(
            require("typst.project").get(opts)
        )
    end
    return bibliography.diagnostics_namespace_for(nil)
end

local function source_for(namespace, entry)
    if type(entry) == "table" then
        return entry
    end

    return {
        module = namespace.source and namespace.source.module,
        method = entry,
    }
end

local function install_namespace(api, namespace, notify)
    local target = api[namespace.name] or {}
    local factory = namespace.source
            and namespace.source.type == "factory"
            and method_cache(namespace.source, notify)
        or nil

    for public_name, entry in pairs(normalize_method_map(namespace.methods)) do
        if type(entry) == "table" and entry.custom then
            target[public_name] = custom_methods[entry.custom]
        elseif factory and type(entry) == "string" then
            target[public_name] = factory(entry)
        else
            local source = source_for(namespace, entry)
            target[public_name] = lazy(source.module, source.method)
        end
    end

    api[namespace.name] = target
end

local function install_global(global)
    _G[global.name] = function(...)
        if global.args == "formatexpr" then
            return require(global.module)[global.method](
                vim.v.lnum,
                vim.v.count
            )
        end
        return require(global.module)[global.method](...)
    end
end

local function append_namespace_symbols(symbols, namespace)
    for public_name in pairs(normalize_method_map(namespace.methods)) do
        symbols[#symbols + 1] = namespace.name .. "." .. public_name
    end
end

local function append_runtime_namespace_symbols(symbols, api, namespace_name)
    local namespace = api[namespace_name]
    if type(namespace) ~= "table" then
        return
    end

    for name, value in pairs(namespace) do
        if type(value) == "function" and name:sub(1, 1) ~= "_" then
            symbols[#symbols + 1] = namespace_name .. "." .. name
        end
    end
end

local function sorted_unique(values)
    local seen = {}
    local out = {}
    for _, value in ipairs(values or {}) do
        if not seen[value] then
            seen[value] = true
            out[#out + 1] = value
        end
    end
    table.sort(out)
    return out
end

local function installed_symbols(api)
    local symbols = {}
    for name, value in pairs(api) do
        if type(value) == "function" and name:sub(1, 1) ~= "_" then
            symbols[#symbols + 1] = name
        elseif type(value) == "table" and name:sub(1, 1) ~= "_" then
            append_runtime_namespace_symbols(symbols, api, name)
        end
    end
    return sorted_unique(symbols)
end

local function stable_symbols(api)
    -- Stable symbols are intentionally spec-only. Runtime installers may add
    -- helpers to stable namespaces, but those remain experimental until the
    -- declarative API spec explicitly lists them.
    local symbols = vim.deepcopy(api_spec.stable_root_functions or {})
    local stable_namespaces = api_spec.stable_namespaces or {}
    for _, symbol in ipairs(api_spec.stable_runtime_symbols or {}) do
        symbols[#symbols + 1] = symbol
    end

    for _, namespace in ipairs(api_spec.namespaces) do
        if stable_namespaces[namespace.name] then
            append_namespace_symbols(symbols, namespace)
        end
    end

    return sorted_unique(symbols)
end

local function experimental_symbols(api)
    local stable = {}
    for _, name in ipairs(stable_symbols(api)) do
        stable[name] = true
    end

    local experimental = {}
    for _, name in ipairs(installed_symbols(api)) do
        if not stable[name] then
            experimental[#experimental + 1] = name
        end
    end
    return sorted_unique(experimental)
end

--- Install stable, experimental, and compatibility API symbols onto `api`.
---@param api table Public module table that receives lazy namespace methods.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification callback captured by factory namespaces.
function M.install(api, notify)
    for _, namespace in ipairs(api_spec.namespaces) do
        install_namespace(api, namespace, notify)
    end

    for _, global in ipairs(api_spec.globals) do
        install_global(global)
    end

    api.public_symbols = function()
        return installed_symbols(api)
    end

    api.stable_symbols = function()
        return stable_symbols(api)
    end

    api.experimental_symbols = function()
        return experimental_symbols(api)
    end
end

M.spec = api_spec

return M
