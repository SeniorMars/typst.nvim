local lexer = require("typst.bibliography.bibtex_lexer")

local M = {}

local function split_concatenation(value)
    local parts = {}
    local start = 1
    local index = 1
    local brace_depth = 0
    local paren_depth = 0
    local quote = false
    local escaped = false

    while index <= #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                quote = false
            end
        elseif char == '"' then
            quote = true
        elseif char == "{" then
            brace_depth = brace_depth + 1
        elseif char == "}" then
            if brace_depth > 0 then
                brace_depth = brace_depth - 1
            end
        elseif char == "(" then
            paren_depth = paren_depth + 1
        elseif char == ")" then
            if paren_depth > 0 then
                paren_depth = paren_depth - 1
            end
        elseif char == "#" and brace_depth == 0 and paren_depth == 0 then
            parts[#parts + 1] = value:sub(start, index - 1)
            start = index + 1
        end
        index = index + 1
    end

    parts[#parts + 1] = value:sub(start)
    return parts
end

local builtin_string_macros = {
    jan = "January",
    feb = "February",
    mar = "March",
    apr = "April",
    may = "May",
    jun = "June",
    jul = "July",
    aug = "August",
    sep = "September",
    oct = "October",
    nov = "November",
    dec = "December",
}

local function strip_balanced(value, open, close)
    if value:sub(1, 1) ~= open or value:sub(-1) ~= close then
        return value
    end

    local end_index = lexer.find_matching(value, 1, #value, open, close)
    if end_index == #value then
        return value:sub(2, -2)
    end

    return value
end

local function normalize_field_space(value)
    return (value or ""):gsub("%s+", " ")
end

local function clean_part(value, macros)
    value = vim.trim(value or "")
    if value == "" then
        return ""
    end

    if value:sub(1, 1) == "{" then
        value = strip_balanced(value, "{", "}")
    elseif value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        value = value:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
    else
        local macro = macros and macros[value:lower()]
        if macro ~= nil then
            return macro
        end
    end

    return normalize_field_space(value)
end

--- Normalize a BibTeX field value.
---
--- Supports `#` concatenation, brace/quote unescaping, and macro substitution.
---@param value string|nil field text to normalize.
---@param macros table|nil optional lowercase macro name map.
---@param opts {trim?: boolean}|nil trim options; defaults trim enabled.
---@return string|nil normalized field value or nil when empty.
function M.clean(value, macros, opts)
    opts = opts or {}
    local parts = {}
    for _, part in ipairs(split_concatenation(value or "")) do
        parts[#parts + 1] = clean_part(part, macros)
    end

    local cleaned = table.concat(parts)
    if opts.trim ~= false then
        cleaned = vim.trim(cleaned)
    end
    return cleaned ~= "" and cleaned or nil
end

---Resolve `@string` macro definitions until reaching a fixed point.
---@param raw_macros table map of macro names to raw text.
---@return table resolved macro map with built-in month macros included.
function M.resolve_macros(raw_macros)
    local macros = vim.deepcopy(builtin_string_macros)
    local names = vim.tbl_keys(raw_macros)
    table.sort(names)

    for _ = 1, #names + 1 do
        local changed = false
        for _, name in ipairs(names) do
            local resolved = M.clean(raw_macros[name], macros, { trim = false })
            if resolved and macros[name] ~= resolved then
                macros[name] = resolved
                changed = true
            end
        end
        if not changed then
            break
        end
    end

    return macros
end

return M
