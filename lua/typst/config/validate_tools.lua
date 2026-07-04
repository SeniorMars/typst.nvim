local schema = require("typst.config.schema")

local M = {}

local validate_string_list = schema.string_list
local validate_command_prefix = schema.command_prefix
local validate_tool_provider = schema.tool_provider
local validate_string_map = schema.string_map

local function optional_string(value, name)
    if value ~= nil and (type(value) ~= "string" or value == "") then
        error(("typst.nvim: %s must be a non-empty string or nil"):format(name))
    end
end

local function optional_provider(value, name)
    if value == nil or type(value) == "function" or type(value) == "table" then
        return
    end
    if type(value) == "string" and value ~= "" then
        return
    end
    error(
        ("typst.nvim: %s must be a non-empty string, function, table, or nil"):format(
            name
        )
    )
end

local function preview_export(export, path, allowed_modes)
    if type(export) ~= "table" then
        error(("typst.nvim: %s must be a table"):format(path))
    end

    local allowed = {}
    for _, mode in ipairs(allowed_modes) do
        allowed[mode] = true
    end
    if not allowed[export.mode] then
        error(
            ("typst.nvim: %s.mode must be one of %s"):format(
                path,
                table.concat(allowed_modes, ", ")
            )
        )
    end

    optional_string(export.profile, path .. ".profile")
    optional_provider(export.provider, path .. ".provider")
    optional_string(export.output_format, path .. ".output_format")
    optional_string(export.output_name, path .. ".output_name")
    optional_string(export.output_dir, path .. ".output_dir")
    validate_string_list(export.extra_args, path .. ".extra_args")
end

local function optional_string_value(value, name)
    if value ~= nil and type(value) ~= "string" then
        error(("typst.nvim: %s must be a string or nil"):format(name))
    end
end

local function preview_browser_style(style, path)
    if type(style) ~= "table" then
        error(("typst.nvim: %s must be a table"):format(path))
    end

    optional_string_value(style.css, path .. ".css")
    optional_string(style.css_path, path .. ".css_path")
    validate_string_map(style.variables, path .. ".variables")

    for key in pairs(style.variables or {}) do
        if not key:match("^%-%-[-_%w]+$") and not key:match("^[-_%w]+$") then
            error(
                ("typst.nvim: %s.variables keys must be CSS variable names or simple identifiers"):format(
                    path
                )
            )
        end
    end
end

local function optional_command_list(value, path)
    if value == nil then
        return
    end
    if type(value) ~= "table" then
        error(
            ("typst.nvim: %s must be a list of command lists or nil"):format(
                path
            )
        )
    end
    for index, command in ipairs(value) do
        validate_command_prefix(command, ("%s[%d]"):format(path, index))
    end
end

local function capability_table(value, path)
    if type(value) ~= "table" then
        error(("typst.nvim: %s must be a table"):format(path))
    end

    for capability, enabled in pairs(value) do
        if type(capability) ~= "string" or type(enabled) ~= "boolean" then
            error(("typst.nvim: %s must map strings to booleans"):format(path))
        end
    end
end

local function non_negative_number(value, path)
    if type(value) ~= "number" or value < 0 then
        error(("typst.nvim: %s must be a non-negative number"):format(path))
    end
end

local function non_negative_integer(value, path)
    if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
        error(("typst.nvim: %s must be a non-negative integer"):format(path))
    end
end

--- Validate diagnostics configuration.
---@param diagnostics table `diagnostics` configuration section.
function M.diagnostics(diagnostics)
    if type(diagnostics) ~= "table" then
        error("typst.nvim: diagnostics must be a table")
    end

    if type(diagnostics.enabled) ~= "boolean" then
        error("typst.nvim: diagnostics.enabled must be a boolean")
    end

    if type(diagnostics.use_quickfix) ~= "boolean" then
        error("typst.nvim: diagnostics.use_quickfix must be a boolean")
    end

    if
        diagnostics.list ~= "quickfix"
        and diagnostics.list ~= "loclist"
        and diagnostics.list ~= "location"
    then
        error(
            'typst.nvim: diagnostics.list must be "quickfix", "loclist", or "location"'
        )
    end

    if type(diagnostics.fonts) ~= "boolean" then
        error("typst.nvim: diagnostics.fonts must be a boolean")
    end

    if
        type(diagnostics.font_scan_timeout_ms) ~= "number"
        or diagnostics.font_scan_timeout_ms < 0
    then
        error(
            "typst.nvim: diagnostics.font_scan_timeout_ms must be a non-negative number"
        )
    end

    non_negative_integer(
        diagnostics.max_buffers_per_publish,
        "diagnostics.max_buffers_per_publish"
    )

    if
        diagnostics.external_paths ~= "bufadd"
        and diagnostics.external_paths ~= "quickfix-only"
        and diagnostics.external_paths ~= "open-files-only"
    then
        error(
            'typst.nvim: diagnostics.external_paths must be "bufadd", "quickfix-only", or "open-files-only"'
        )
    end

    if
        diagnostics.source ~= "fallback"
        and diagnostics.source ~= "always"
        and diagnostics.source ~= "off"
    then
        error(
            'typst.nvim: diagnostics.source must be "fallback", "always", or "off"'
        )
    end
end

--- Validate preview integration configuration.
---@param preview table `preview` configuration section.
function M.preview(preview)
    if type(preview) ~= "table" then
        error("typst.nvim: preview must be a table")
    end

    validate_tool_provider(
        preview.provider,
        "preview.provider",
        { "native", "typst-preview.nvim" },
        "preview"
    )

    if
        preview.native ~= "browser"
        and preview.native ~= "viewer"
        and preview.native ~= "auto"
    then
        error(
            'typst.nvim: preview.native must be "browser", "viewer", or "auto"'
        )
    end

    preview_export(
        preview.export,
        "preview.export",
        { "compile", "profile", "provider" }
    )

    if type(preview.cache) ~= "table" then
        error("typst.nvim: preview.cache must be a table")
    end
    if type(preview.cache.enabled) ~= "boolean" then
        error("typst.nvim: preview.cache.enabled must be a boolean")
    end
    non_negative_number(preview.cache.max_entries, "preview.cache.max_entries")
    non_negative_number(preview.cache.max_bytes, "preview.cache.max_bytes")
    non_negative_number(preview.cache.ttl_ms, "preview.cache.ttl_ms")

    if preview.open ~= nil and type(preview.open) ~= "function" then
        error("typst.nvim: preview.open must be a function or nil")
    end

    if preview.stop ~= nil and type(preview.stop) ~= "function" then
        error("typst.nvim: preview.stop must be a function or nil")
    end

    if preview.refresh ~= nil and type(preview.refresh) ~= "function" then
        error("typst.nvim: preview.refresh must be a function or nil")
    end

    if preview.forward ~= nil and type(preview.forward) ~= "function" then
        error("typst.nvim: preview.forward must be a function or nil")
    end

    if preview.inverse ~= nil and type(preview.inverse) ~= "function" then
        error("typst.nvim: preview.inverse must be a function or nil")
    end

    if type(preview.reuse) ~= "boolean" then
        error("typst.nvim: preview.reuse must be a boolean")
    end

    if type(preview.follow_buffer) ~= "boolean" then
        error("typst.nvim: preview.follow_buffer must be a boolean")
    end

    capability_table(preview.capabilities, "preview.capabilities")

    if type(preview.source_maps) ~= "table" then
        error("typst.nvim: preview.source_maps must be a table")
    end

    optional_provider(
        preview.source_maps.provider,
        "preview.source_maps.provider"
    )
    if
        preview.source_maps.forward ~= nil
        and type(preview.source_maps.forward) ~= "function"
    then
        error(
            "typst.nvim: preview.source_maps.forward must be a function or nil"
        )
    end
    if
        preview.source_maps.inverse ~= nil
        and type(preview.source_maps.inverse) ~= "function"
    then
        error(
            "typst.nvim: preview.source_maps.inverse must be a function or nil"
        )
    end
    capability_table(
        preview.source_maps.capabilities,
        "preview.source_maps.capabilities"
    )

    if preview.fallback ~= "view" and preview.fallback ~= "error" then
        error('typst.nvim: preview.fallback must be "view" or "error"')
    end

    if type(preview.browser) ~= "table" then
        error("typst.nvim: preview.browser must be a table")
    end

    if type(preview.browser.host) ~= "string" or preview.browser.host == "" then
        error("typst.nvim: preview.browser.host must be a non-empty string")
    end

    if
        type(preview.browser.port) ~= "number"
        or preview.browser.port < 0
        or preview.browser.port % 1 ~= 0
    then
        error("typst.nvim: preview.browser.port must be a non-negative integer")
    end

    if type(preview.browser.server) ~= "boolean" then
        error("typst.nvim: preview.browser.server must be a boolean")
    end

    if type(preview.browser.allow_remote) ~= "boolean" then
        error("typst.nvim: preview.browser.allow_remote must be a boolean")
    end

    if
        preview.browser.token ~= "auto"
        and (
            type(preview.browser.token) ~= "string"
            or preview.browser.token == ""
        )
    then
        error(
            'typst.nvim: preview.browser.token must be "auto" or a non-empty string'
        )
    end

    if
        type(preview.browser.output_dir) ~= "string"
        or preview.browser.output_dir == ""
    then
        error(
            "typst.nvim: preview.browser.output_dir must be a non-empty string"
        )
    end

    non_negative_number(
        preview.browser.max_artifact_bytes,
        "preview.browser.max_artifact_bytes"
    )

    if
        type(preview.browser.refresh_ms) ~= "number"
        or preview.browser.refresh_ms < 0
    then
        error(
            "typst.nvim: preview.browser.refresh_ms must be a non-negative number"
        )
    end

    if
        type(preview.browser.reload_throttle_ms) ~= "number"
        or preview.browser.reload_throttle_ms < 0
    then
        error(
            "typst.nvim: preview.browser.reload_throttle_ms must be a non-negative number"
        )
    end

    if
        preview.browser.performance ~= "default"
        and preview.browser.performance ~= "safari"
        and preview.browser.performance ~= "fast"
    then
        error(
            'typst.nvim: preview.browser.performance must be "default", "safari", or "fast"'
        )
    end

    optional_string(preview.browser.app, "preview.browser.app")
    optional_command_list(preview.browser.commands, "preview.browser.commands")

    if
        preview.browser.open ~= nil
        and type(preview.browser.open) ~= "function"
    then
        error("typst.nvim: preview.browser.open must be a function or nil")
    end

    preview_browser_style(preview.browser.style, "preview.browser.style")

    preview_export(
        preview.browser.export,
        "preview.browser.export",
        { "inherit", "compile", "profile", "provider" }
    )
end

--- Validate formatting tool configuration.
---@param format table `format` configuration section.
function M.format(format)
    if type(format) ~= "table" then
        error("typst.nvim: format must be a table")
    end

    validate_tool_provider(
        format.provider,
        "format.provider",
        { "auto", "tinymist", "typstyle", "command", "prose" },
        "format"
    )

    if format.command ~= nil then
        validate_command_prefix(format.command, "format.command")
    end

    validate_string_list(format.extra_args, "format.extra_args")

    if type(format.timeout_ms) ~= "number" or format.timeout_ms < 0 then
        error("typst.nvim: format.timeout_ms must be a non-negative number")
    end

    if type(format.prose_width) ~= "number" or format.prose_width < 1 then
        error("typst.nvim: format.prose_width must be a positive number")
    end
end

--- Validate lint tool configuration.
---@param lint table `lint` configuration section.
function M.lint(lint)
    if type(lint) ~= "table" then
        error("typst.nvim: lint must be a table")
    end

    validate_tool_provider(
        lint.provider,
        "lint.provider",
        { "typst", "tinymist", "command" },
        "lint"
    )

    if lint.command ~= nil then
        validate_command_prefix(lint.command, "lint.command")
    end

    validate_string_list(lint.extra_args, "lint.extra_args")

    if type(lint.timeout_ms) ~= "number" or lint.timeout_ms < 0 then
        error("typst.nvim: lint.timeout_ms must be a non-negative number")
    end
end

--- Validate grammar-check tool configuration.
---@param grammar table `grammar` configuration section.
function M.grammar(grammar)
    if type(grammar) ~= "table" then
        error("typst.nvim: grammar must be a table")
    end

    validate_tool_provider(
        grammar.provider,
        "grammar.provider",
        { "command", "textidote", "vlty" },
        "grammar"
    )

    if grammar.command ~= nil then
        validate_command_prefix(grammar.command, "grammar.command")
    end

    validate_string_list(grammar.extra_args, "grammar.extra_args")

    if type(grammar.timeout_ms) ~= "number" or grammar.timeout_ms < 0 then
        error("typst.nvim: grammar.timeout_ms must be a non-negative number")
    end

    if grammar.stdin ~= nil and type(grammar.stdin) ~= "boolean" then
        error("typst.nvim: grammar.stdin must be a boolean or nil")
    end

    if grammar.file_arg ~= nil and type(grammar.file_arg) ~= "boolean" then
        error("typst.nvim: grammar.file_arg must be a boolean or nil")
    end
end

return M
