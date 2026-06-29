local providers = require("typst.integrations.providers")
local schema = require("typst.config.schema")

local M = {}

local validate_string_list = schema.string_list
local validate_command_prefix = schema.command_prefix

local function validate_viewer_command(value, name)
    if value == nil or type(value) == "function" or type(value) == "string" then
        return
    end

    if type(value) == "table" then
        validate_command_prefix(value, name)
        return
    end

    error(
        ("typst.nvim: %s must be a function, string, list, or nil"):format(name)
    )
end

local function validate_viewer_provider(name, provider)
    if type(name) ~= "string" or name == "" then
        error("typst.nvim: viewer.providers keys must be non-empty strings")
    end

    if type(provider) ~= "table" then
        error(("typst.nvim: viewer.providers.%s must be a table"):format(name))
    end

    validate_viewer_command(
        provider.open,
        ("viewer.providers.%s.open"):format(name)
    )
    if provider.reload ~= nil and type(provider.reload) ~= "function" then
        error(
            ("typst.nvim: viewer.providers.%s.reload must be a function or nil"):format(
                name
            )
        )
    end
    validate_viewer_command(
        provider.forward,
        ("viewer.providers.%s.forward"):format(name)
    )
    validate_viewer_command(
        provider.inverse,
        ("viewer.providers.%s.inverse"):format(name)
    )
    validate_string_list(
        provider.args,
        ("viewer.providers.%s.args"):format(name)
    )
    validate_string_list(
        provider.forward_args,
        ("viewer.providers.%s.forward_args"):format(name)
    )
    validate_string_list(
        provider.inverse_args,
        ("viewer.providers.%s.inverse_args"):format(name)
    )

    if provider.capabilities ~= nil then
        if type(provider.capabilities) ~= "table" then
            error(
                ("typst.nvim: viewer.providers.%s.capabilities must be a table"):format(
                    name
                )
            )
        end

        for capability, enabled in pairs(provider.capabilities) do
            if type(capability) ~= "string" or type(enabled) ~= "boolean" then
                error(
                    ("typst.nvim: viewer.providers.%s.capabilities must map strings to booleans"):format(
                        name
                    )
                )
            end
        end
    end
end

--- Validate PDF viewer configuration.
---@param viewer table `viewer` configuration section.
function M.validate(viewer)
    if type(viewer) ~= "table" then
        error("typst.nvim: viewer must be a table")
    end

    if type(viewer.provider) ~= "string" or viewer.provider == "" then
        error("typst.nvim: viewer.provider must be a non-empty string")
    end

    validate_viewer_command(viewer.open, "viewer.open")
    if viewer.reload ~= nil and type(viewer.reload) ~= "function" then
        error("typst.nvim: viewer.reload must be a function or nil")
    end
    validate_string_list(viewer.args, "viewer.args")
    validate_viewer_command(viewer.forward, "viewer.forward")
    validate_string_list(viewer.forward_args, "viewer.forward_args")
    validate_viewer_command(viewer.inverse, "viewer.inverse")
    validate_string_list(viewer.inverse_args, "viewer.inverse_args")

    if viewer.capabilities ~= nil then
        if type(viewer.capabilities) ~= "table" then
            error("typst.nvim: viewer.capabilities must be a table")
        end

        for capability, enabled in pairs(viewer.capabilities) do
            if type(capability) ~= "string" or type(enabled) ~= "boolean" then
                error(
                    "typst.nvim: viewer.capabilities must map strings to booleans"
                )
            end
        end
    end

    if type(viewer.providers) ~= "table" then
        error("typst.nvim: viewer.providers must be a table")
    end

    for name, provider in pairs(viewer.providers) do
        validate_viewer_provider(name, provider)
    end

    if
        viewer.providers[viewer.provider] == nil
        and not providers.has("viewer", viewer.provider)
    then
        error(
            ("typst.nvim: viewer.provider %q has no matching viewer.providers entry"):format(
                viewer.provider
            )
        )
    end
end

return M
