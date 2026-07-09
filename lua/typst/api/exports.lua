local api_spec = require("typst.api.spec")

local M = {}
local owned_globals = rawget(_G, "__typst_nvim_owned_globals")
if type(owned_globals) ~= "table" then
    owned_globals = {}
    rawset(_G, "__typst_nvim_owned_globals", owned_globals)
end
local last_global_install = {
    installed = {},
    skipped = {},
}
local warned_experimental_symbols = {}
local wrapped_experimental_functions = setmetatable({}, { __mode = "k" })

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
        if target[public_name] == nil then
            if type(entry) == "table" and entry.custom then
                target[public_name] = custom_methods[entry.custom]
            elseif factory and type(entry) == "string" then
                target[public_name] = factory(entry)
            else
                local source = source_for(namespace, entry)
                target[public_name] = lazy(source.module, source.method)
            end
        end
    end

    api[namespace.name] = target
end

local function log_global(level, message, context)
    local ok, log = pcall(require, "typst.core.log")
    if ok and type(log) == "table" and type(log.add) == "function" then
        pcall(log.add, level, message, context)
    end
end

local function typst_global_name(name)
    return type(name) == "string" and name:match("^typst_nvim_") ~= nil
end

local function global_is_owned(name)
    return owned_globals[name] ~= nil and _G[name] == owned_globals[name]
end

local function build_global(global)
    return function(...)
        if global.args == "formatexpr" then
            return require(global.module)[global.method](
                vim.v.lnum,
                vim.v.count
            )
        end
        if global.args == "foldexpr" then
            return require(global.module)[global.method](vim.v.lnum)
        end
        return require(global.module)[global.method](...)
    end
end

local function install_global(global)
    if not typst_global_name(global.name) then
        log_global("error", "refused invalid typst.nvim global name", {
            name = global.name,
        })
        return false, "invalid_name"
    end

    if global_is_owned(global.name) then
        return true
    end

    local existing = _G[global.name]
    if existing ~= nil and existing ~= owned_globals[global.name] then
        owned_globals[global.name] = nil
        if global.allow_overwrite ~= true then
            log_global("warn", "kept existing non-typst global", {
                name = global.name,
            })
            return false, "collision"
        end
    end

    local fn = build_global(global)
    _G[global.name] = fn
    owned_globals[global.name] = fn
    return true
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

local function stable_symbol_set(api)
    local stable = {}
    for _, name in ipairs(stable_symbols(api)) do
        stable[name] = true
    end
    return stable
end

local function experimental_warnings_enabled()
    local ok, config = pcall(require, "typst.config")
    if not ok or type(config) ~= "table" then
        return false
    end
    local current = config.unsafe_get()
    return type(current) == "table"
        and type(current.api) == "table"
        and current.api.experimental_warnings == true
end

local function warn_experimental_symbol(symbol, notify)
    if
        warned_experimental_symbols[symbol]
        or not experimental_warnings_enabled()
    then
        return
    end

    warned_experimental_symbols[symbol] = true
    local message = ("typst.nvim Lua API %s is experimental"):format(symbol)
    log_global("warn", message, {
        symbol = symbol,
        stable_symbols = "require('typst').stable_symbols()",
    })
    if type(notify) == "function" then
        pcall(notify, message, vim.log.levels.WARN)
    end
end

local function wrap_experimental(symbol, fn, notify)
    if type(fn) ~= "function" then
        return fn
    end
    if wrapped_experimental_functions[fn] then
        return fn
    end
    local wrapped = function(...)
        warn_experimental_symbol(symbol, notify)
        return fn(...)
    end
    wrapped_experimental_functions[wrapped] = {
        symbol = symbol,
        wrapped = fn,
    }
    return wrapped
end

local function wrap_installed_experimental_symbols(api, notify)
    local stable = stable_symbol_set(api)
    for _, namespace in ipairs(api_spec.namespaces or {}) do
        local target = api[namespace.name]
        if type(target) == "table" then
            for public_name in pairs(normalize_method_map(namespace.methods)) do
                local symbol = namespace.name .. "." .. public_name
                if not stable[symbol] then
                    target[public_name] =
                        wrap_experimental(symbol, target[public_name], notify)
                end
            end
        end
    end
end

--- Install v:lua globals owned by the public API spec.
---
--- Globals are process-wide. typst.nvim only installs names with the
--- `typst_nvim_` prefix, and it does not overwrite user/plugin functions
--- unless a spec entry explicitly opts into that behavior.
---@return table summary Installed/skipped global names.
function M.install_globals()
    local summary = {
        installed = {},
        skipped = {},
    }
    for _, global in ipairs(api_spec.globals) do
        local ok, reason = install_global(global)
        if ok then
            summary.installed[#summary.installed + 1] = global.name
        else
            summary.skipped[#summary.skipped + 1] = {
                name = global.name,
                reason = reason,
            }
        end
    end
    last_global_install = vim.deepcopy(summary)
    return summary
end

--- Remove globals still owned by this typst.nvim instance.
---
--- If another plugin or user code replaced one of the functions, reset keeps
--- that value and drops typst.nvim ownership instead of deleting it.
---@return table summary Removed/preserved global names.
function M.reset_globals()
    local summary = {
        removed = {},
        preserved = {},
    }
    local expected = {}
    for _, global in ipairs(api_spec.globals) do
        local name = global.name
        expected[name] = true
        if global_is_owned(name) then
            _G[name] = nil
            owned_globals[name] = nil
            summary.removed[#summary.removed + 1] = name
        elseif owned_globals[name] ~= nil then
            owned_globals[name] = nil
            summary.preserved[#summary.preserved + 1] = name
        end
    end
    for name, fn in pairs(owned_globals) do
        if typst_global_name(name) and expected[name] ~= true then
            if _G[name] == fn then
                _G[name] = nil
                summary.removed[#summary.removed + 1] = name
            else
                summary.preserved[#summary.preserved + 1] = name
            end
            owned_globals[name] = nil
        end
    end
    return summary
end

--- Return a snapshot of globals still owned by typst.nvim.
---@return table<string, boolean> globals Owned global names.
function M.owned_globals()
    local snapshot = {}
    for name in pairs(owned_globals) do
        if global_is_owned(name) then
            snapshot[name] = true
        end
    end
    return snapshot
end

--- Return installed/skipped v:lua global status for health and diagnostics.
---@return table status Summary of expected, owned, installed, and skipped globals.
function M.global_status()
    local expected = {}
    for _, global in ipairs(api_spec.globals or {}) do
        expected[#expected + 1] = global.name
    end
    table.sort(expected)

    local owned = M.owned_globals()
    local owned_names = {}
    for name in pairs(owned) do
        owned_names[#owned_names + 1] = name
    end
    table.sort(owned_names)

    return {
        expected = expected,
        expected_count = #expected,
        owned = owned_names,
        owned_count = #owned_names,
        installed = vim.deepcopy(last_global_install.installed or {}),
        installed_count = #(last_global_install.installed or {}),
        skipped = vim.deepcopy(last_global_install.skipped or {}),
        skipped_count = #(last_global_install.skipped or {}),
    }
end

--- Install stable, experimental, and compatibility API symbols onto `api`.
---@param api table Public module table that receives lazy namespace methods.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification callback captured by factory namespaces.
function M.install(api, notify)
    for _, namespace in ipairs(api_spec.namespaces) do
        install_namespace(api, namespace, notify)
    end
    wrap_installed_experimental_symbols(api, notify)

    M.install_globals()

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

function M.experimental_wrapper(symbol, fn, notify)
    return wrap_experimental(symbol, fn, notify)
end

function M.reset_experimental_warnings()
    warned_experimental_symbols = {}
end

M.spec = api_spec

return M
