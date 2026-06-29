local schema = require("typst.config.schema")

local M = {}

local validate_string_list = schema.string_list
local validate_string = schema.string
local validate_command_prefix = schema.command_prefix

local watch_output_values = {
    auto = true,
    human = true,
    structured = true,
}

local function validate_watch_output(value, name)
    if type(value) ~= "string" or not watch_output_values[value] then
        error(
            ('typst.nvim: %s must be "auto", "human", or "structured"'):format(
                name
            )
        )
    end
end

local function validate_compile_profile(name, profile)
    if type(name) ~= "string" or name == "" then
        error("typst.nvim: compile.profiles keys must be non-empty strings")
    end

    if type(profile) ~= "table" then
        error(("typst.nvim: compile.profiles.%s must be a table"):format(name))
    end

    if profile.output_format ~= nil then
        validate_string(
            profile.output_format,
            ("compile.profiles.%s.output_format"):format(name)
        )
    end

    if profile.output_name ~= nil then
        validate_string(
            profile.output_name,
            ("compile.profiles.%s.output_name"):format(name)
        )
    end

    if profile.output_dir ~= nil and type(profile.output_dir) ~= "string" then
        error(
            ("typst.nvim: compile.profiles.%s.output_dir must be a string or nil"):format(
                name
            )
        )
    end

    if profile.extra_args ~= nil then
        validate_string_list(
            profile.extra_args,
            ("compile.profiles.%s.extra_args"):format(name)
        )
    end

    if profile.watch_output ~= nil then
        validate_watch_output(
            profile.watch_output,
            ("compile.profiles.%s.watch_output"):format(name)
        )
    end

    if profile.watch_structured_args ~= nil then
        validate_string_list(
            profile.watch_structured_args,
            ("compile.profiles.%s.watch_structured_args"):format(name)
        )
    end

    if profile.deps ~= nil and type(profile.deps) ~= "boolean" then
        error(
            ("typst.nvim: compile.profiles.%s.deps must be a boolean or nil"):format(
                name
            )
        )
    end

    if profile.open ~= nil and type(profile.open) ~= "boolean" then
        error(
            ("typst.nvim: compile.profiles.%s.open must be a boolean or nil"):format(
                name
            )
        )
    end

    if profile.typst_open ~= nil and type(profile.typst_open) ~= "boolean" then
        error(
            ("typst.nvim: compile.profiles.%s.typst_open must be a boolean or nil"):format(
                name
            )
        )
    end
end

local function validate_fragment_template(name, template)
    if type(name) ~= "string" or name == "" then
        error(
            "typst.nvim: compile.fragments.templates keys must be non-empty strings"
        )
    end

    local prefix = ("compile.fragments.templates.%s"):format(name)
    if type(template) == "function" then
        return
    end

    if type(template) == "string" then
        if not template:find("{body}", 1, true) then
            error(
                ("typst.nvim: %s string template must contain {body}"):format(
                    prefix
                )
            )
        end
        return
    end

    if type(template) ~= "table" then
        error(
            ("typst.nvim: %s must be a table, string, or function"):format(
                prefix
            )
        )
    end

    for _, field in ipairs({ "prefix", "suffix" }) do
        if template[field] ~= nil and type(template[field]) ~= "string" then
            error(
                ("typst.nvim: %s.%s must be a string or nil"):format(
                    prefix,
                    field
                )
            )
        end
    end

    if template.source ~= nil then
        if
            type(template.source) ~= "string"
            and type(template.source) ~= "function"
        then
            error(
                ("typst.nvim: %s.source must be a string, function, or nil"):format(
                    prefix
                )
            )
        end

        if
            type(template.source) == "string"
            and not template.source:find("{body}", 1, true)
        then
            error(("typst.nvim: %s.source must contain {body}"):format(prefix))
        end
    end

    if template.output_format ~= nil then
        validate_string(
            template.output_format,
            ("%s.output_format"):format(prefix)
        )
    end

    if template.output_name ~= nil then
        validate_string(template.output_name, ("%s.output_name"):format(prefix))
    end

    if template.output_dir ~= nil and type(template.output_dir) ~= "string" then
        error(
            ("typst.nvim: %s.output_dir must be a string or nil"):format(prefix)
        )
    end

    if template.source_dir ~= nil and type(template.source_dir) ~= "string" then
        error(
            ("typst.nvim: %s.source_dir must be a string or nil"):format(prefix)
        )
    end

    if template.extra_args ~= nil then
        validate_string_list(
            template.extra_args,
            ("%s.extra_args"):format(prefix)
        )
    end

    if template.deps ~= nil and type(template.deps) ~= "boolean" then
        error(("typst.nvim: %s.deps must be a boolean or nil"):format(prefix))
    end

    if template.open ~= nil and type(template.open) ~= "boolean" then
        error(("typst.nvim: %s.open must be a boolean or nil"):format(prefix))
    end
end

local function validate_compile_fragments(fragments)
    if type(fragments) ~= "table" then
        error("typst.nvim: compile.fragments must be a table")
    end

    validate_string(fragments.default, "compile.fragments.default")

    if
        fragments.output_dir ~= nil
        and type(fragments.output_dir) ~= "string"
    then
        error(
            "typst.nvim: compile.fragments.output_dir must be a string or nil"
        )
    end

    if
        fragments.source_dir ~= nil
        and type(fragments.source_dir) ~= "string"
    then
        error(
            "typst.nvim: compile.fragments.source_dir must be a string or nil"
        )
    end

    if type(fragments.templates) ~= "table" then
        error("typst.nvim: compile.fragments.templates must be a table")
    end

    for name, template in pairs(fragments.templates) do
        validate_fragment_template(name, template)
    end

    if fragments.templates[fragments.default] == nil then
        error(
            ("typst.nvim: compile.fragments.default %q has no template"):format(
                fragments.default
            )
        )
    end
end

local function validate_command_template(value, name)
    if value == nil then
        return
    end

    validate_command_prefix(value, name)
end

local function validate_compile_runner(runner, name)
    if type(runner) ~= "table" then
        error(("typst.nvim: %s must be a table"):format(name))
    end

    validate_command_template(runner.compile, name .. ".compile")
    validate_command_template(runner.watch, name .. ".watch")

    for _, field in ipairs({ "output", "cwd" }) do
        if
            runner[field] ~= nil
            and type(runner[field]) ~= "string"
            and type(runner[field]) ~= "function"
        then
            error(
                ("typst.nvim: %s.%s must be a string, function, or nil"):format(
                    name,
                    field
                )
            )
        end
    end
end

local function validate_provider(provider)
    if provider == nil or provider == "typst" then
        return
    end

    if type(provider) == "string" or type(provider) == "function" then
        return
    end

    if type(provider) ~= "table" then
        error(
            "typst.nvim: compile.provider must be a string, function, table, or nil"
        )
    end

    for _, name in ipairs({ "compile", "start", "stop", "status", "output" }) do
        if type(provider[name]) ~= "function" then
            error(
                ("typst.nvim: compile.provider.%s must be a function"):format(
                    name
                )
            )
        end
    end
end

--- Validate compile/watch configuration.
---@param compile table `compile` configuration section.
function M.validate(compile)
    if type(compile) ~= "table" then
        error("typst.nvim: compile must be a table")
    end

    validate_provider(compile.provider)

    if type(compile.deps) ~= "boolean" then
        error("typst.nvim: compile.deps must be a boolean")
    end

    if type(compile.open) ~= "boolean" then
        error("typst.nvim: compile.open must be a boolean")
    end

    if type(compile.typst_open) ~= "boolean" then
        error("typst.nvim: compile.typst_open must be a boolean")
    end

    if
        type(compile.provider_timeout_ms) ~= "number"
        or compile.provider_timeout_ms < 0
    then
        error(
            "typst.nvim: compile.provider_timeout_ms must be a non-negative number"
        )
    end

    if type(compile.profiles) ~= "table" then
        error("typst.nvim: compile.profiles must be a table")
    end

    for name, profile in pairs(compile.profiles) do
        validate_compile_profile(name, profile)
    end

    validate_compile_runner(compile.generic, "compile.generic")
    validate_compile_runner(compile.task, "compile.task")
    validate_compile_fragments(compile.fragments)
    validate_string_list(compile.extra_args, "compile.extra_args")
    validate_watch_output(compile.watch_output, "compile.watch_output")
    validate_string_list(
        compile.watch_structured_args,
        "compile.watch_structured_args"
    )
end

return M
