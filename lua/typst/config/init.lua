local compile_config = require("typst.config.compile")
local defaults_provider = require("typst.config.defaults")
local validation = require("typst.config.validate")

local M = {}

local defaults = defaults_provider.values()
local current = vim.deepcopy(defaults)
local generation = 0
local readonly_cache = nil
local readonly_generation = -1
local readonly_backing = setmetatable({}, { __mode = "k" })

local function readonly_error(_, key)
    error(
        (
            "typst.nvim: config.get() returns a read-only view; attempted to set %s. "
            .. "Use require('typst').setup({...}) to reconfigure, "
            .. "or config.snapshot() to copy values. config.unsafe_get() is internal."
        ):format(tostring(key)),
        2
    )
end

local function readonly_view(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local backing = {}
    local proxy = {}
    seen[value] = proxy
    readonly_backing[proxy] = backing

    for key, child in pairs(value) do
        backing[key] = readonly_view(child, seen)
    end

    return setmetatable(proxy, {
        __index = backing,
        __newindex = readonly_error,
        __metatable = "typst.nvim read-only config",
    })
end

local function materialize(value, seen)
    if type(value) ~= "table" then
        return value
    end

    local backing = readonly_backing[value]
    if not backing then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, child in pairs(backing) do
        copy[key] = materialize(child, seen)
    end
    return copy
end

--- Validate and install the active plugin configuration.
---@param opts? table Plugin configuration partial to validate and apply.
---@return table config Active configuration table after validation.
function M.setup(opts)
    if type(opts) == "table" and opts.docs ~= nil then
        error(
            "typst.nvim: docs configuration was removed; use package and symbol resource commands instead"
        )
    end

    defaults = defaults_provider.values()
    local user_opts = materialize(opts or {})
    local next_config =
        vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_opts)
    -- Validate before swapping the active config so a failed setup cannot leave
    -- half-applied options behind for commands or ftplugin attach.
    validation.validate(next_config)
    current = next_config
    generation = generation + 1
    readonly_cache = nil
    readonly_generation = -1
    return M.get()
end

--- Return the current active configuration as a read-only view.
---
--- The returned table protects nested options from ordinary writes. Internal
--- hot paths that intentionally need the live mutable table must use
--- `unsafe_get()`. Consumers that need a traversable/mutable copy should use
--- `snapshot()`.
---@return table config Read-only active configuration table.
function M.get()
    if readonly_cache == nil or readonly_generation ~= generation then
        readonly_cache = readonly_view(current)
        readonly_generation = generation
    end
    return readonly_cache
end

--- Return the current active configuration table.
---
--- This is the live mutable configuration for internal hot paths only.
---@return table config Current active configuration table.
function M.unsafe_get()
    return current
end

--- Return an isolated copy of the active configuration.
---@return table config Deep copy of the active configuration.
function M.snapshot()
    return vim.deepcopy(current)
end

--- Return the active configuration generation.
---@return integer generation Monotonic counter incremented after successful setup.
function M.generation()
    return generation
end

--- Return known compile profile names in sorted order.
---@return string[] names Known compile profile names.
function M.profile_names()
    local names = vim.tbl_keys(current.compile.profiles or {})
    table.sort(names)
    return names
end

--- Return a compact label for the configured compile provider.
---@return string label Provider label used in events and logs.
function M.provider_label()
    local provider = current.compile.provider
    if provider == nil or provider == "typst" then
        return "typst"
    end

    if type(provider) == "string" then
        return provider
    end

    if type(provider) == "function" then
        return "callback"
    end

    return provider.name or "table"
end

--- Build a run-specific config by applying a compile profile overlay.
---@param profile string|nil Compile profile name to resolve.
---@param overrides? table Runtime overrides (for example from user input).
---@return table config Resolved run-time configuration.
function M.for_run(profile, overrides)
    local run = vim.deepcopy(current)
    profile = profile ~= "" and profile or nil

    if profile then
        local profile_config = current.compile.profiles[profile]
        if not profile_config then
            error(("typst.nvim: unknown compile profile %q"):format(profile))
        end

        run.compile.profile = profile

        -- Profiles are compile/run overlays, not alternate full configs. The
        -- schema lives with compile validation so supported keys and overlay
        -- behavior cannot drift apart.
        compile_config.apply_profile(run, profile_config)
    end

    overrides = overrides or {}
    if overrides.open ~= nil then
        run.compile.open = overrides.open
    end

    if overrides.typst_open ~= nil then
        run.compile.typst_open = overrides.typst_open
    end

    return run
end

--- Return a fresh copy of the default configuration.
---@return table defaults Default configuration table.
function M.defaults()
    return vim.deepcopy(defaults_provider.values())
end

--- Return the default output directory for compiled artifacts.
---@return string path Default output directory.
function M.default_output_dir()
    return defaults_provider.output_dir()
end

--- Return the default output directory for rendered fragments.
---@return string path Default fragments output directory.
function M.default_fragments_output_dir()
    return defaults_provider.fragments_output_dir()
end

--- Return the default output directory for render workflow artifacts.
---@return string path Default render output directory.
function M.default_render_output_dir()
    return defaults_provider.render_output_dir()
end

--- Return the default XDG cache source directory for opt-in file-backed renders.
---@return string path Default render source directory.
function M.default_render_source_dir()
    return defaults_provider.render_source_dir()
end

return M
