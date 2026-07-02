local compile_config = require("typst.config.compile")
local defaults_provider = require("typst.config.defaults")
local tables = require("typst.core.tables")
local util = require("typst.core.util")
local validation = require("typst.config.validate")

local M = {}

local defaults = defaults_provider.values()
local current = vim.deepcopy(defaults)
local generation = 0
local readonly_cache = nil
local readonly_generation = -1
local readonly_backing = setmetatable({}, { __mode = "k" })
local last_unknown_keys = {}

local dynamic_config_paths = {
    api = true,
    ["conceal.custom"] = true,
    ["conceal.reveal_by_category"] = true,
    main = true,
    ["compile.profiles"] = true,
    ["compile.fragments.templates"] = true,
    ["exports.profiles"] = true,
    ["imaps.mappings"] = true,
    ["integrations.tinymist.capabilities"] = true,
    ["integrations.tinymist.init_options"] = true,
    ["integrations.tinymist.settings"] = true,
    ["preview.browser.style.variables"] = true,
    ["syntax.packages"] = true,
    ["viewer.providers"] = true,
}

local known_optional_paths = {
    main = true,
    metadata_version = true,
    output_name = true,
    root = true,
    ["compile.fragments.source_dir"] = true,
    ["compile.generic.compile"] = true,
    ["compile.generic.cwd"] = true,
    ["compile.generic.output"] = true,
    ["compile.generic.watch"] = true,
    ["compile.provider"] = true,
    ["compile.task.compile"] = true,
    ["compile.task.cwd"] = true,
    ["compile.task.output"] = true,
    ["compile.task.watch"] = true,
    ["conceal.reveal_insert"] = true,
    ["exports.default"] = true,
    ["exports.provider"] = true,
    ["folds.text"] = true,
    ["grammar.command"] = true,
    ["grammar.file_arg"] = true,
    ["grammar.stdin"] = true,
    ["integrations.tinymist.capabilities"] = true,
    ["integrations.tinymist.cmd"] = true,
    ["integrations.tinymist.on_attach"] = true,
    ["lint.command"] = true,
    ["picker.custom"] = true,
    ["preview.browser.app"] = true,
    ["preview.browser.commands"] = true,
    ["preview.browser.export.output_dir"] = true,
    ["preview.browser.export.output_format"] = true,
    ["preview.browser.export.output_name"] = true,
    ["preview.browser.export.profile"] = true,
    ["preview.browser.export.provider"] = true,
    ["preview.browser.open"] = true,
    ["preview.browser.style.css"] = true,
    ["preview.browser.style.css_path"] = true,
    ["preview.export.output_dir"] = true,
    ["preview.export.output_format"] = true,
    ["preview.export.output_name"] = true,
    ["preview.export.profile"] = true,
    ["preview.export.provider"] = true,
    ["preview.forward"] = true,
    ["preview.inverse"] = true,
    ["preview.open"] = true,
    ["preview.refresh"] = true,
    ["preview.source_maps.forward"] = true,
    ["preview.source_maps.inverse"] = true,
    ["preview.stop"] = true,
    ["render.display_provider"] = true,
    ["render.provider"] = true,
    ["viewer.forward"] = true,
    ["viewer.inverse"] = true,
    ["viewer.open"] = true,
    ["viewer.reload"] = true,
}

local export_profile_fields = {
    "command",
    "compile_format",
    "creation_timestamp",
    "cwd",
    "diagnostic_format",
    "extra_args",
    "features",
    "font_path",
    "font_paths",
    "format",
    "ignore_embedded_fonts",
    "ignore_system_fonts",
    "input",
    "inputs",
    "jobs",
    "name",
    "no_pdf_tags",
    "output_dir",
    "output_format",
    "output_name",
    "package_cache_path",
    "package_path",
    "pages",
    "pdf_standard",
    "pdf_standards",
    "ppi",
    "pretty",
    "provider",
    "stdout",
    "timings",
    "typst_format",
}

local export_profile_allowed = {}
for _, field in ipairs(export_profile_fields) do
    export_profile_allowed[field] = true
end

local function key_path(parent, key)
    key = tostring(key)
    return parent ~= "" and (parent .. "." .. key) or key
end

local function indexed_path(parent, index)
    return ("%s[%d]"):format(parent, index)
end

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

local function normalize_main_mapping(user_opts)
    if type(user_opts) ~= "table" or type(user_opts.main) ~= "table" then
        return
    end

    local base = util.normalize(vim.fn.getcwd())
    local normalized = {}
    local seen = {}
    for root, main in pairs(user_opts.main) do
        local normalized_root
        if type(root) == "string" and root ~= "" then
            local resolved = util.resolve_path(root, base)
            normalized_root = resolved or root
        else
            normalized_root = root
        end

        local seen_key = ("%s:%s"):format(
            type(normalized_root),
            tostring(normalized_root)
        )
        if seen[seen_key] then
            error(
                ("typst.nvim: duplicate main table key after normalization: %s"):format(
                    tostring(normalized_root)
                )
            )
        end
        seen[seen_key] = true
        normalized[normalized_root] = main
    end
    user_opts.main = normalized
end

local function unknown_key_mode(user_opts)
    local mode = type(user_opts) == "table" and user_opts.validation or nil
    if mode == "strict" then
        return "strict"
    end
    if mode == "off" or mode == false then
        return "off"
    end
    return "warn"
end

local function set_from_list(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[value] = true
    end
    return out
end

local function collect_table_unknowns(value, allowed_keys, prefix, out)
    if type(value) ~= "table" then
        return
    end
    for key in pairs(value) do
        if allowed_keys[key] ~= true then
            out[#out + 1] = key_path(prefix, key)
        end
    end
end

local function collect_export_profile_unknowns(value, prefix, out)
    if type(value) ~= "table" then
        return
    end
    if tables.is_list(value) then
        for index, item in ipairs(value) do
            collect_export_profile_unknowns(
                item,
                indexed_path(prefix, index),
                out
            )
        end
        return
    end
    collect_table_unknowns(value, export_profile_allowed, prefix, out)
end

local function collect_dynamic_value_unknowns(user_opts, prefix, out)
    if prefix == "compile.profiles" then
        local allowed = set_from_list(compile_config.profile_override_keys())
        for name, profile in pairs(user_opts) do
            collect_table_unknowns(
                profile,
                allowed,
                key_path(prefix, name),
                out
            )
        end
        return true
    end

    if prefix == "exports.profiles" then
        for name, profile in pairs(user_opts) do
            collect_export_profile_unknowns(
                profile,
                key_path(prefix, name),
                out
            )
        end
        return true
    end

    return false
end

local function collect_unknown_keys(user_opts, allowed, prefix, out)
    if type(user_opts) ~= "table" or type(allowed) ~= "table" then
        return
    end

    prefix = prefix or ""
    out = out or {}
    if collect_dynamic_value_unknowns(user_opts, prefix, out) then
        table.sort(out)
        return out
    end
    if dynamic_config_paths[prefix] then
        return out
    end

    for key, value in pairs(user_opts) do
        local child_path = key_path(prefix, key)
        local allowed_value = allowed[key]
        if allowed_value == nil and not known_optional_paths[child_path] then
            out[#out + 1] = child_path
        elseif
            type(value) == "table"
            and type(allowed_value) == "table"
            and not tables.is_list(value)
        then
            collect_unknown_keys(value, allowed_value, child_path, out)
        end
    end

    table.sort(out)
    return out
end

local function log_unknown_keys(keys)
    local ok, log = pcall(require, "typst.core.log")
    if ok and log and type(log.add) == "function" then
        log.add("warn", "unknown Typst config keys", { keys = keys })
    end
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
    -- Normalization rewrites config tables for runtime lookup. Work on an
    -- isolated copy so setup never mutates a plugin-manager/user-owned opts
    -- table that may be reused for later reconfiguration.
    local user_opts = vim.deepcopy(materialize(opts or {}))
    normalize_main_mapping(user_opts)
    last_unknown_keys = collect_unknown_keys(user_opts, defaults, "", {}) or {}
    local unknown_mode = unknown_key_mode(user_opts)
    if #last_unknown_keys > 0 then
        local message = "typst.nvim: unknown configuration keys: "
            .. table.concat(last_unknown_keys, ", ")
        if unknown_mode == "strict" then
            error(message)
        elseif unknown_mode == "warn" then
            log_unknown_keys(last_unknown_keys)
        end
    end

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

--- Return the unknown user config keys seen during the most recent setup.
---@return string[] keys Fully qualified unknown config keys.
function M.last_unknown_keys()
    return vim.deepcopy(last_unknown_keys)
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
