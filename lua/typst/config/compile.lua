local schema = require("typst.config.schema")

local M = {}

local validate_string_list = schema.string_list
local validate_string = schema.string
local validate_command_prefix = schema.command_prefix
local WATCH_OUTPUT_WAIT_MAX_MS = 60000

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

local function validate_optional_string(value, name)
    if value ~= nil then
        validate_string(value, name)
    end
end

local function validate_optional_output_dir(value, name)
    if value ~= nil and type(value) ~= "string" then
        error(("typst.nvim: %s must be a string or nil"):format(name))
    end
end

local function validate_optional_string_list(value, name)
    if value ~= nil then
        validate_string_list(value, name)
    end
end

local function validate_optional_watch_output(value, name)
    if value ~= nil then
        validate_watch_output(value, name)
    end
end

local function validate_optional_boolean(value, name)
    if value ~= nil and type(value) ~= "boolean" then
        error(("typst.nvim: %s must be a boolean or nil"):format(name))
    end
end

local function validate_optional_nonnegative_number(value, name)
    if value ~= nil and (type(value) ~= "number" or value < 0) then
        error(
            ("typst.nvim: %s must be a non-negative number or nil"):format(name)
        )
    end
    if value ~= nil and value > WATCH_OUTPUT_WAIT_MAX_MS then
        error(
            ("typst.nvim: %s must be at most %d ms or nil"):format(
                name,
                WATCH_OUTPUT_WAIT_MAX_MS
            )
        )
    end
end

local profile_overrides = {
    {
        key = "output_format",
        target = { "output_format" },
        validate = validate_optional_string,
    },
    {
        key = "output_name",
        target = { "output_name" },
        validate = validate_optional_string,
    },
    {
        key = "output_dir",
        target = { "output_dir" },
        validate = validate_optional_output_dir,
    },
    {
        key = "extra_args",
        target = { "compile", "extra_args" },
        validate = validate_optional_string_list,
        deepcopy = true,
    },
    {
        key = "watch_output",
        target = { "compile", "watch_output" },
        validate = validate_optional_watch_output,
    },
    {
        key = "watch_output_wait_ms",
        target = { "compile", "watch_output_wait_ms" },
        validate = validate_optional_nonnegative_number,
    },
    {
        key = "watch_structured_args",
        target = { "compile", "watch_structured_args" },
        validate = validate_optional_string_list,
        deepcopy = true,
    },
    {
        key = "deps",
        target = { "compile", "deps" },
        validate = validate_optional_boolean,
    },
    {
        key = "open",
        target = { "compile", "open" },
        validate = validate_optional_boolean,
    },
    {
        key = "typst_open",
        target = { "compile", "typst_open" },
        validate = validate_optional_boolean,
    },
}

local profile_override_by_key = {}
for _, field in ipairs(profile_overrides) do
    profile_override_by_key[field.key] = field
end

local function profile_override_name(profile_name, key)
    return ("compile.profiles.%s.%s"):format(profile_name, key)
end

local function allowed_profile_keys()
    local keys = {}
    for index, field in ipairs(profile_overrides) do
        keys[index] = field.key
    end
    return keys
end

local function validate_compile_profile(name, profile)
    if type(name) ~= "string" or name == "" then
        error("typst.nvim: compile.profiles keys must be non-empty strings")
    end

    if type(profile) ~= "table" then
        error(("typst.nvim: compile.profiles.%s must be a table"):format(name))
    end

    for key in pairs(profile) do
        local field = profile_override_by_key[key]
        if not field then
            error(
                ("typst.nvim: compile.profiles.%s.%s is not supported; allowed keys: %s"):format(
                    name,
                    tostring(key),
                    table.concat(allowed_profile_keys(), ", ")
                )
            )
        end

        field.validate(profile[key], profile_override_name(name, key))
    end
end

local function set_profile_value(run_config, field, value)
    local target = run_config
    for index = 1, #field.target - 1 do
        target = target[field.target[index]]
    end

    target[field.target[#field.target]] = field.deepcopy and vim.deepcopy(value)
        or value
end

--- Return compile-profile override keys in overlay order.
---@return string[] keys Supported `compile.profiles.*` field names.
function M.profile_override_keys()
    return allowed_profile_keys()
end

--- Apply one validated compile-profile table to a run config.
---@param run_config table Resolved run configuration to mutate.
---@param profile table Compile profile table from `compile.profiles`.
---@return table run_config The same run config after overlay.
function M.apply_profile(run_config, profile)
    for _, field in ipairs(profile_overrides) do
        local value = profile[field.key]
        if value ~= nil then
            set_profile_value(run_config, field, value)
        end
    end
    return run_config
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

    if compile.stdin ~= nil then
        error(
            "typst.nvim: compile.stdin is internal; use compile.fragments for stdin-backed fragment runs"
        )
    end

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
    if
        type(compile.watch_output_wait_ms) ~= "number"
        or compile.watch_output_wait_ms < 0
    then
        error(
            "typst.nvim: compile.watch_output_wait_ms must be a non-negative number"
        )
    end
    if compile.watch_output_wait_ms > WATCH_OUTPUT_WAIT_MAX_MS then
        error(
            ("typst.nvim: compile.watch_output_wait_ms must be at most %d ms"):format(
                WATCH_OUTPUT_WAIT_MAX_MS
            )
        )
    end
    validate_string_list(
        compile.watch_structured_args,
        "compile.watch_structured_args"
    )
end

return M
