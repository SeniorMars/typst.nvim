local config = require("typst.config")
local util = require("typst.core.util")

local M = {}

local values = {
    math = {},
}

local function normalize_kind(kind)
    if type(kind) ~= "string" or kind == "" then
        error("typst.nvim: conceal custom kind must be a non-empty string", 2)
    end
    if not values[kind] then
        error(
            ("typst.nvim: unsupported conceal custom kind %q"):format(kind),
            2
        )
    end
    return kind
end

local function validate_name(name)
    if type(name) ~= "string" or name == "" then
        error("typst.nvim: conceal custom name must be a non-empty string", 2)
    end
end

local function validate_replacement(replacement)
    if type(replacement) ~= "string" then
        error("typst.nvim: conceal custom replacement must be a string", 2)
    end
    if replacement == "" then
        return
    end

    local safety = config.unsafe_get().conceal.safety or {}
    if util.scalar_count(replacement) ~= 1 then
        error(
            "typst.nvim: conceal custom replacement must be empty or exactly one character for native conceal",
            2
        )
    end

    local width = vim.fn.strdisplaywidth(replacement)
    if width > (safety.max_display_width or 1) then
        error(
            "typst.nvim: conceal custom replacement display width exceeds conceal.safety.max_display_width",
            2
        )
    end
    if width == 0 and not safety.allow_combining then
        error(
            "typst.nvim: conceal custom replacement has zero display width; enable conceal.safety.allow_combining",
            2
        )
    end
end

function M.all()
    return values
end

function M.register(kind, name, replacement)
    kind = normalize_kind(kind)
    validate_name(name)
    validate_replacement(replacement)

    values[kind][name] = replacement
    return replacement
end

function M.unregister(kind, name)
    kind = normalize_kind(kind)
    validate_name(name)

    local replacement = values[kind][name]
    values[kind][name] = nil
    return replacement
end

function M.get(kind)
    kind = normalize_kind(kind or "math")
    return vim.deepcopy(values[kind])
end

function M.reset()
    values = {
        math = {},
    }
end

return M
