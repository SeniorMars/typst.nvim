local schema = require("typst.config.schema")
local util = require("typst.core.util")

local M = {}

local validate_string_map = schema.string_map
local validate_boolean_map = schema.boolean_map

local function validate_conceal_replacement(value, name, safety)
    if type(value) ~= "string" then
        error(("typst.nvim: %s must be a string"):format(name))
    end

    if value == "" then
        return
    end

    if util.scalar_count(value) ~= 1 then
        error(
            ("typst.nvim: %s must be empty or exactly one character for native conceal"):format(
                name
            )
        )
    end

    local width = vim.fn.strdisplaywidth(value)
    if width > safety.max_display_width then
        error(
            ("typst.nvim: %s display width exceeds conceal.safety.max_display_width"):format(
                name
            )
        )
    end

    if width == 0 and not safety.allow_combining then
        error(
            ("typst.nvim: %s has zero display width; enable conceal.safety.allow_combining to allow it"):format(
                name
            )
        )
    end
end

local function validate_conceal_map(value, name, safety)
    validate_string_map(value, name)

    for key, item in pairs(value) do
        validate_conceal_replacement(item, ("%s.%s"):format(name, key), safety)
    end
end

local allowed_conceal_categories = {
    math_symbols = true,
    math_scripts = true,
    math_delimiters = true,
    markup_delimiters = true,
    headings = true,
    lists = true,
    raw_blocks = true,
    raw_block_languages = true,
    labels = true,
    reference_markers = true,
    function_wrappers = true,
    emoji = true,
}

local legacy_conceal_categories = {
    references = "reference_markers",
    citations = "reference_markers",
}

local allowed_function_wrappers = {
    strong = true,
    emph = true,
    underline = true,
    strike = true,
}

local function validate_conceal_categories(categories)
    if type(categories) ~= "table" then
        error("typst.nvim: conceal.categories must be a table")
    end

    for name, enabled in pairs(categories) do
        local replacement = legacy_conceal_categories[name]
        if replacement then
            error(
                ("typst.nvim: conceal.categories.%s was removed; use conceal.categories.%s instead"):format(
                    name,
                    replacement
                )
            )
        end

        if not allowed_conceal_categories[name] then
            error(
                ("typst.nvim: unknown conceal category: conceal.categories.%s"):format(
                    tostring(name)
                )
            )
        end

        if name == "function_wrappers" then
            validate_boolean_map(
                enabled,
                "conceal.categories.function_wrappers"
            )
            if type(enabled) == "table" then
                for wrapper in pairs(enabled) do
                    if not allowed_function_wrappers[wrapper] then
                        error(
                            ("typst.nvim: unknown function wrapper conceal category: conceal.categories.function_wrappers.%s"):format(
                                tostring(wrapper)
                            )
                        )
                    end
                end
            end
        elseif type(enabled) ~= "boolean" then
            error(
                ("typst.nvim: conceal.categories.%s must be a boolean"):format(
                    name
                )
            )
        end
    end
end

--- Validate conceal configuration.
---@param conceal table `conceal` configuration section.
function M.validate(conceal)
    if type(conceal) ~= "table" then
        error("typst.nvim: conceal must be a table")
    end

    if type(conceal.enabled) ~= "boolean" then
        error("typst.nvim: conceal.enabled must be a boolean")
    end

    if conceal.reveal ~= "node" and conceal.reveal ~= "none" then
        error('typst.nvim: conceal.reveal must be "node" or "none"')
    end

    if type(conceal.conceallevel) ~= "number" or conceal.conceallevel < 0 then
        error("typst.nvim: conceal.conceallevel must be a non-negative number")
    end

    if
        type(conceal.viewport_margin) ~= "number"
        or conceal.viewport_margin < 0
    then
        error(
            "typst.nvim: conceal.viewport_margin must be a non-negative number"
        )
    end

    validate_conceal_categories(conceal.categories)

    if type(conceal.safety) ~= "table" then
        error("typst.nvim: conceal.safety must be a table")
    end

    if
        type(conceal.safety.max_display_width) ~= "number"
        or conceal.safety.max_display_width < 0
    then
        error(
            "typst.nvim: conceal.safety.max_display_width must be a non-negative number"
        )
    end

    if type(conceal.safety.allow_combining) ~= "boolean" then
        error("typst.nvim: conceal.safety.allow_combining must be a boolean")
    end

    if type(conceal.custom) ~= "table" then
        error("typst.nvim: conceal.custom must be a table")
    end

    validate_conceal_map(
        conceal.custom.math,
        "conceal.custom.math",
        conceal.safety
    )
end

return M
