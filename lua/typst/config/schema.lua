local providers = require("typst.integrations.providers")

local M = {}

--- Validate and normalize an optional list.
---@param value? table Value to validate.
---@param name string User-facing option name for error messages.
---@return table list Original list, or an empty list for nil.
function M.as_list(value, name)
    if value == nil then
        return {}
    end

    if type(value) ~= "table" then
        error(("typst.nvim: %s must be a list"):format(name))
    end

    local count = 0
    local max_index = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error(
                ("typst.nvim: %s must be an array list; invalid key %s"):format(
                    name,
                    vim.inspect(key)
                )
            )
        end
        count = count + 1
        max_index = math.max(max_index, key)
    end

    if count ~= max_index then
        for index = 1, max_index do
            if value[index] == nil then
                error(
                    ("typst.nvim: %s must not contain holes; missing index %d"):format(
                        name,
                        index
                    )
                )
            end
        end
    end

    return value
end

--- Validate an optional list of non-empty strings.
---@param value? table Value to validate.
---@param name string User-facing option name for error messages.
---@return string[] list Original list, or an empty list for nil.
function M.string_list(value, name)
    local list = M.as_list(value, name)

    for index, item in ipairs(list) do
        if type(item) ~= "string" or item == "" then
            error(
                ("typst.nvim: %s[%d] must be a non-empty string"):format(
                    name,
                    index
                )
            )
        end
    end

    return list
end

--- Validate a required non-empty string.
---@param value any Value to validate.
---@param name string User-facing option name for error messages.
function M.string(value, name)
    if type(value) ~= "string" or value == "" then
        error(("typst.nvim: %s must be a non-empty string"):format(name))
    end
end

--- Validate a command prefix accepted as a string or string list.
---@param value string|string[] Value to validate.
---@param name string User-facing option name for error messages.
function M.command_prefix(value, name)
    if type(value) == "string" and value ~= "" then
        return
    end

    if type(value) ~= "table" then
        error(
            ("typst.nvim: %s must be a non-empty string or list of strings"):format(
                name
            )
        )
    end

    local list = M.as_list(value, name)
    if #list == 0 then
        error(("typst.nvim: %s must not be an empty list"):format(name))
    end

    for index, item in ipairs(list) do
        if type(item) ~= "string" or item == "" then
            error(
                ("typst.nvim: %s[%d] must be a non-empty string"):format(
                    name,
                    index
                )
            )
        end
    end
end

--- Validate a tool provider selector or inline provider implementation.
---@param value any Provider value to validate.
---@param name string User-facing option name for error messages.
---@param allowed string[] Built-in provider names allowed for this option.
---@param provider_kind? string Registry kind used for named custom providers.
function M.tool_provider(value, name, allowed, provider_kind)
    if type(value) == "function" then
        return
    end

    if type(value) == "table" then
        return
    end

    if type(value) == "string" then
        for _, item in ipairs(allowed) do
            if value == item then
                return
            end
        end

        if provider_kind and providers.has(provider_kind, value) then
            return
        end
    end

    error(
        ("typst.nvim: %s must be one of %s, a function, or table"):format(
            name,
            table.concat(allowed, ", ")
        )
    )
end

--- Validate a string-keyed map of string values.
---@param value table Value to validate.
---@param name string User-facing option name for error messages.
function M.string_map(value, name)
    if type(value) ~= "table" then
        error(("typst.nvim: %s must be a table"):format(name))
    end

    for key, item in pairs(value) do
        if type(key) ~= "string" or key == "" then
            error(
                ("typst.nvim: %s keys must be non-empty strings"):format(name)
            )
        end
        if type(item) ~= "string" then
            error(("typst.nvim: %s.%s must be a string"):format(name, key))
        end
    end
end

--- Validate a boolean or string-keyed map of booleans.
---@param value boolean|table Value to validate.
---@param name string User-facing option name for error messages.
function M.boolean_map(value, name)
    if type(value) == "boolean" then
        return
    end

    if type(value) ~= "table" then
        error(("typst.nvim: %s must be a boolean or table"):format(name))
    end

    for key, item in pairs(value) do
        if type(key) ~= "string" or key == "" then
            error(
                ("typst.nvim: %s keys must be non-empty strings"):format(name)
            )
        end
        if type(item) ~= "boolean" then
            error(("typst.nvim: %s.%s must be a boolean"):format(name, key))
        end
    end
end

return M
