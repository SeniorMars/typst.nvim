local editor = require("typst.config.validate_editor")
local sections = require("typst.config.sections")
local schema = require("typst.config.schema")
local tables = require("typst.core.tables")
local tools = require("typst.config.validate_tools")

local M = {}

local validate_string_list = schema.string_list
local validate_string = schema.string
local validate_command_prefix = schema.command_prefix

local function validate_optional_string(value, name)
    if value ~= nil then
        validate_string(value, name)
    end
end

local function validate_string_or_list(value, name)
    if value == nil or type(value) == "string" then
        return
    end
    validate_string_list(value, name)
end

local function validate_string_or_number(value, name)
    if value == nil or type(value) == "string" or type(value) == "number" then
        return
    end
    error(("typst.nvim: %s must be a string, number, or nil"):format(name))
end

local function validate_optional_boolean(value, name)
    if value ~= nil and type(value) ~= "boolean" then
        error(("typst.nvim: %s must be a boolean or nil"):format(name))
    end
end

local function validate_optional_provider(value, name)
    if
        value ~= nil
        and type(value) ~= "string"
        and type(value) ~= "function"
        and type(value) ~= "table"
    then
        error(
            ("typst.nvim: %s must be a string, function, table, or nil"):format(
                name
            )
        )
    end
    if type(value) == "string" and value == "" then
        error(
            ("typst.nvim: %s must be a non-empty string, function, table, or nil"):format(
                name
            )
        )
    end
end

local function validate_inputs(value, name)
    if value == nil or type(value) == "string" then
        return
    end
    if type(value) ~= "table" then
        error(("typst.nvim: %s must be a string or table"):format(name))
    end
    if tables.is_list(value) then
        validate_string_list(value, name)
        return
    end
    for key, input in pairs(value) do
        if type(key) ~= "string" or key == "" then
            error(
                ("typst.nvim: %s keys must be non-empty strings"):format(name)
            )
        end
        if
            type(input) ~= "string"
            and type(input) ~= "number"
            and type(input) ~= "boolean"
        then
            error(
                ("typst.nvim: %s.%s must be a string, number, or boolean"):format(
                    name,
                    key
                )
            )
        end
    end
end

local function validate_export_spec(spec, name)
    if type(spec) == "string" then
        return
    end
    if type(spec) ~= "table" then
        error(("typst.nvim: %s must be a string or table"):format(name))
    end

    for _, field in ipairs({
        "format",
        "output_format",
        "typst_format",
        "compile_format",
        "output_name",
        "output_dir",
        "name",
        "cwd",
        "package_path",
        "package_cache_path",
        "diagnostic_format",
        "timings",
    }) do
        validate_optional_string(spec[field], ("%s.%s"):format(name, field))
    end

    validate_string_or_list(spec.pages, name .. ".pages")
    validate_string_or_list(spec.pdf_standard, name .. ".pdf_standard")
    validate_string_or_list(spec.pdf_standards, name .. ".pdf_standards")
    validate_string_or_list(spec.features, name .. ".features")
    validate_string_or_list(spec.font_paths, name .. ".font_paths")
    validate_string_or_list(spec.font_path, name .. ".font_path")
    validate_string_or_number(
        spec.creation_timestamp,
        name .. ".creation_timestamp"
    )
    validate_string_or_number(spec.jobs, name .. ".jobs")
    validate_inputs(spec.inputs, name .. ".inputs")
    validate_inputs(spec.input, name .. ".input")

    if spec.ppi ~= nil and type(spec.ppi) ~= "number" then
        error(("typst.nvim: %s.ppi must be a number or nil"):format(name))
    end
    validate_optional_boolean(spec.pretty, name .. ".pretty")
    validate_optional_boolean(spec.no_pdf_tags, name .. ".no_pdf_tags")
    validate_optional_boolean(
        spec.ignore_system_fonts,
        name .. ".ignore_system_fonts"
    )
    validate_optional_boolean(
        spec.ignore_embedded_fonts,
        name .. ".ignore_embedded_fonts"
    )
    validate_optional_boolean(spec.stdout, name .. ".stdout")
    if spec.extra_args ~= nil then
        validate_string_list(spec.extra_args, name .. ".extra_args")
    end
    if spec.command ~= nil then
        validate_command_prefix(spec.command, name .. ".command")
    end
    validate_optional_provider(spec.provider, name .. ".provider")
    if spec.command ~= nil and spec.provider ~= nil then
        error(
            ("typst.nvim: %s cannot set both command and provider"):format(name)
        )
    end
end

local function validate_exports(exports)
    if exports == nil then
        return
    end
    if type(exports) ~= "table" then
        error("typst.nvim: exports must be a table")
    end
    if exports.default ~= nil then
        validate_string(exports.default, "exports.default")
    end
    if
        exports.provider ~= nil
        and type(exports.provider) ~= "string"
        and type(exports.provider) ~= "function"
        and type(exports.provider) ~= "table"
    then
        error(
            "typst.nvim: exports.provider must be a string, function, table, or nil"
        )
    end
    if type(exports.profiles) ~= "table" then
        error("typst.nvim: exports.profiles must be a table")
    end
    if type(exports.timeout_ms) ~= "number" or exports.timeout_ms < 0 then
        error("typst.nvim: exports.timeout_ms must be a non-negative number")
    end
    for name, profile in pairs(exports.profiles) do
        if type(name) ~= "string" or name == "" then
            error("typst.nvim: exports.profiles keys must be non-empty strings")
        end
        if tables.is_list(profile) then
            for index, spec in ipairs(profile) do
                validate_export_spec(
                    spec,
                    ("exports.profiles.%s[%d]"):format(name, index)
                )
            end
        else
            validate_export_spec(profile, ("exports.profiles.%s"):format(name))
        end
    end
end

local function validate_api(api)
    if type(api) ~= "table" then
        error("typst.nvim: api must be a table")
    end
end

local function validate_bibliography(bibliography)
    if type(bibliography) ~= "table" then
        error("typst.nvim: bibliography must be a table")
    end

    if
        bibliography.completion ~= "auto"
        and bibliography.completion ~= "project"
        and bibliography.completion ~= "tinymist"
        and bibliography.completion ~= "off"
        and bibliography.completion ~= true
        and bibliography.completion ~= false
    then
        error(
            'typst.nvim: bibliography.completion must be "auto", "project", "tinymist", "off", true, or false'
        )
    end

    validate_string_list(
        bibliography.attachment_fields,
        "bibliography.attachment_fields"
    )
    validate_string_list(
        bibliography.attachment_paths,
        "bibliography.attachment_paths"
    )
end

local function validate_integrations(integrations)
    if type(integrations) ~= "table" then
        error("typst.nvim: integrations must be a table")
    end

    local semantic = integrations.semantic
    if semantic ~= nil then
        if type(semantic) ~= "table" then
            error("typst.nvim: integrations.semantic must be a table")
        end
        validate_optional_provider(
            semantic.provider,
            "integrations.semantic.provider"
        )
    end

    local tinymist = integrations.tinymist
    if tinymist == nil then
        return
    end

    if type(tinymist) ~= "table" then
        error("typst.nvim: integrations.tinymist must be a table")
    end

    if
        tinymist.lsp ~= "auto"
        and tinymist.lsp ~= "detect"
        and tinymist.lsp ~= "off"
        and tinymist.lsp ~= "start"
        and tinymist.lsp ~= true
        and tinymist.lsp ~= false
    then
        error(
            'typst.nvim: integrations.tinymist.lsp must be "auto", "detect", "off", "start", true, or false'
        )
    end

    validate_string_list(
        tinymist.client_names or { "tinymist" },
        "integrations.tinymist.client_names"
    )

    if tinymist.cmd ~= nil then
        validate_command_prefix(tinymist.cmd, "integrations.tinymist.cmd")
    end

    if tinymist.path ~= nil then
        validate_string(tinymist.path, "integrations.tinymist.path")
    end

    if tinymist.settings ~= nil and type(tinymist.settings) ~= "table" then
        error("typst.nvim: integrations.tinymist.settings must be a table")
    end

    if
        tinymist.init_options ~= nil
        and type(tinymist.init_options) ~= "table"
    then
        error("typst.nvim: integrations.tinymist.init_options must be a table")
    end

    if
        tinymist.capabilities ~= nil
        and type(tinymist.capabilities) ~= "table"
    then
        error("typst.nvim: integrations.tinymist.capabilities must be a table")
    end

    if tinymist.on_attach ~= nil and type(tinymist.on_attach) ~= "function" then
        error("typst.nvim: integrations.tinymist.on_attach must be a function")
    end
end

local function validate_render(render)
    if type(render) ~= "table" then
        error("typst.nvim: render must be a table")
    end

    if
        render.provider ~= nil
        and type(render.provider) ~= "string"
        and type(render.provider) ~= "function"
        and type(render.provider) ~= "table"
    then
        error(
            "typst.nvim: render.provider must be a string, function, table, or nil"
        )
    end

    if
        render.display_provider ~= nil
        and type(render.display_provider) ~= "string"
        and type(render.display_provider) ~= "function"
        and type(render.display_provider) ~= "table"
    then
        error(
            "typst.nvim: render.display_provider must be a string, function, table, or nil"
        )
    end

    validate_string(render.output_format, "render.output_format")

    if render.output_dir ~= nil and type(render.output_dir) ~= "string" then
        error("typst.nvim: render.output_dir must be a string or nil")
    end

    if render.source_dir ~= nil and type(render.source_dir) ~= "string" then
        error("typst.nvim: render.source_dir must be a string or nil")
    end

    if render.source_mode ~= "stdin" and render.source_mode ~= "file" then
        error('typst.nvim: render.source_mode must be "stdin" or "file"')
    end

    if type(render.timeout_ms) ~= "number" or render.timeout_ms < 0 then
        error("typst.nvim: render.timeout_ms must be a non-negative number")
    end

    if type(render.cache) ~= "boolean" and type(render.cache) ~= "table" then
        error("typst.nvim: render.cache must be a boolean or table")
    end

    if type(render.cache) == "table" then
        if
            render.cache.enabled ~= nil
            and type(render.cache.enabled) ~= "boolean"
        then
            error("typst.nvim: render.cache.enabled must be a boolean or nil")
        end
        for _, key in ipairs({ "max_entries", "max_bytes", "ttl_ms" }) do
            if
                render.cache[key] ~= nil
                and (
                    type(render.cache[key]) ~= "number"
                    or render.cache[key] < 0
                )
            then
                error(
                    ("typst.nvim: render.cache.%s must be a non-negative number or nil"):format(
                        key
                    )
                )
            end
        end
    end

    if
        render.max_inline_image_bytes ~= nil
        and (
            type(render.max_inline_image_bytes) ~= "number"
            or render.max_inline_image_bytes < 0
        )
    then
        error(
            "typst.nvim: render.max_inline_image_bytes must be a non-negative number or nil"
        )
    end

    if type(render.open) ~= "boolean" then
        error("typst.nvim: render.open must be a boolean")
    end
end

--- Validate the fully merged typst.nvim configuration table.
---@param config table Configuration table after defaults/user options merge.
function M.validate(config)
    if
        config.validation ~= nil
        and config.validation ~= "warn"
        and config.validation ~= "strict"
        and config.validation ~= "off"
        and config.validation ~= false
    then
        error(
            'typst.nvim: validation must be "warn", "strict", "off", false, or nil'
        )
    end

    validate_command_prefix(config.executable, "executable")

    if config.metadata_version ~= nil then
        validate_string(config.metadata_version, "metadata_version")
    end

    validate_string(config.output_format, "output_format")

    if config.output_name ~= nil then
        validate_string(config.output_name, "output_name")
    end

    if config.output_dir ~= nil and type(config.output_dir) ~= "string" then
        error("typst.nvim: output_dir must be a string or nil")
    end
    if
        config.allow_external_output ~= nil
        and type(config.allow_external_output) ~= "boolean"
    then
        error("typst.nvim: allow_external_output must be a boolean or nil")
    end

    sections.compile(config.compile)
    validate_exports(config.exports)
    validate_render(config.render)

    if
        config.root ~= nil
        and type(config.root) ~= "string"
        and type(config.root) ~= "function"
    then
        error("typst.nvim: root must be a string, function, or nil")
    end

    sections.main(config.main)
    sections.project(config.project)
    validate_integrations(config.integrations)
    validate_api(config.api)
    validate_bibliography(config.bibliography)
    tools.diagnostics(config.diagnostics)
    sections.viewer(config.viewer)
    tools.preview(config.preview)
    editor.syntax(config.syntax)
    sections.conceal(config.conceal)
    editor.completion(config.completion)
    editor.picker(config.picker)
    tools.format(config.format)
    tools.lint(config.lint)
    tools.grammar(config.grammar)
    editor.structural_actions(config.structural_actions)
    editor.folds(config.folds)
    editor.toc(config.toc)
    editor.indent(config.indent)
    editor.matchparen(config.matchparen)
    editor.imaps(config.imaps)
    editor.mappings(config.mappings)
    editor.log(config.log)
    validate_string_list(config.root_markers, "root_markers")
end

return M
