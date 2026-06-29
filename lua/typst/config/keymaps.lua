local M = {}

local function validate_mapping(value, name, prefix)
    if value ~= nil and value ~= false and type(value) ~= "string" then
        error(
            ("typst.nvim: %s.%s must be a string, false, or nil"):format(
                prefix,
                name
            )
        )
    end
end

--- Validate TOC-specific keymap configuration.
---@param mappings table TOC mapping configuration.
function M.validate_toc(mappings)
    if mappings ~= nil and type(mappings) ~= "table" then
        error("typst.nvim: toc.mappings must be a table")
    end

    mappings = mappings or {}
    if type(mappings.enabled) ~= "boolean" then
        error("typst.nvim: toc.mappings.enabled must be a boolean")
    end

    validate_mapping(mappings.jump, "jump", "toc.mappings")
    validate_mapping(mappings.preview, "preview", "toc.mappings")
    validate_mapping(mappings.close, "close", "toc.mappings")
    validate_mapping(mappings.refresh, "refresh", "toc.mappings")
    validate_mapping(mappings.toggle, "toggle", "toc.mappings")
    validate_mapping(mappings.toggle_layer, "toggle_layer", "toc.mappings")
    validate_mapping(mappings.filter, "filter", "toc.mappings")
    validate_mapping(mappings.clear_filter, "clear_filter", "toc.mappings")
end

--- Validate all keymap configuration sections.
---@param mappings table Keymap configuration.
function M.validate(mappings)
    if type(mappings) ~= "table" then
        error("typst.nvim: mappings must be a table")
    end

    if type(mappings.enabled) ~= "boolean" then
        error("typst.nvim: mappings.enabled must be a boolean")
    end

    validate_mapping(mappings.next_heading, "next_heading", "mappings")
    validate_mapping(mappings.previous_heading, "previous_heading", "mappings")
    validate_mapping(mappings.next_heading_end, "next_heading_end", "mappings")
    validate_mapping(
        mappings.previous_heading_end,
        "previous_heading_end",
        "mappings"
    )
    validate_mapping(mappings.next_block, "next_block", "mappings")
    validate_mapping(mappings.previous_block, "previous_block", "mappings")
    validate_mapping(mappings.next_block_end, "next_block_end", "mappings")
    validate_mapping(
        mappings.previous_block_end,
        "previous_block_end",
        "mappings"
    )
    validate_mapping(mappings.next_equation, "next_equation", "mappings")
    validate_mapping(
        mappings.previous_equation,
        "previous_equation",
        "mappings"
    )
    validate_mapping(
        mappings.next_equation_end,
        "next_equation_end",
        "mappings"
    )
    validate_mapping(
        mappings.previous_equation_end,
        "previous_equation_end",
        "mappings"
    )
    validate_mapping(mappings.next_raw_block, "next_raw_block", "mappings")
    validate_mapping(
        mappings.previous_raw_block,
        "previous_raw_block",
        "mappings"
    )
    validate_mapping(mappings.next_comment, "next_comment", "mappings")
    validate_mapping(mappings.previous_comment, "previous_comment", "mappings")
    validate_mapping(mappings.match, "match", "mappings")
    validate_mapping(mappings.follow, "follow", "mappings")
    validate_mapping(mappings.hover, "hover", "mappings")
    validate_mapping(mappings.repeat_transform, "repeat_transform", "mappings")

    if mappings.commands ~= nil and type(mappings.commands) ~= "table" then
        error("typst.nvim: mappings.commands must be a table")
    end

    for name, value in pairs(mappings.commands or {}) do
        validate_mapping(value, "commands." .. name, "mappings")
    end

    if mappings.insert ~= nil and type(mappings.insert) ~= "table" then
        error("typst.nvim: mappings.insert must be a table")
    end

    for name, value in pairs(mappings.insert or {}) do
        validate_mapping(value, "insert." .. name, "mappings")
    end

    if
        mappings.textobjects ~= nil
        and type(mappings.textobjects) ~= "table"
    then
        error("typst.nvim: mappings.textobjects must be a table")
    end

    for name, value in pairs(mappings.textobjects or {}) do
        validate_mapping(value, "textobjects." .. name, "mappings")
    end
end

return M
