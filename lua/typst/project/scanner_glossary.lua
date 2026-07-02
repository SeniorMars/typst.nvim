local scanner_helpers = require("typst.project.index.scanner_helpers")

local M = {}

local trim = scanner_helpers.trim
local add_unique = scanner_helpers.add_unique
local source_location = scanner_helpers.source_location
local strip_line_comment = scanner_helpers.strip_line_comment
local strip_strings = scanner_helpers.strip_strings
local find_code = scanner_helpers.find_code

local glossary_entry_fields = {
    body = true,
    desc = true,
    description = true,
    group = true,
    key = true,
    long = true,
    name = true,
    parent = true,
    plural = true,
    see = true,
    short = true,
    symbol = true,
    text = true,
}

local function looks_like_glossary_name(name)
    name = (name or ""):lower()
    return name:find("gloss", 1, true)
        or name:find("acronym", 1, true)
        or name:find("abbrev", 1, true)
        or name:find("term", 1, true)
end

local function delimiter_delta(line)
    local cleaned = strip_strings(strip_line_comment(line))
    local delta = 0
    for char in cleaned:gmatch("[%(%)%[%]%{%}]") do
        if char == "(" or char == "[" or char == "{" then
            delta = delta + 1
        else
            delta = delta - 1
        end
    end
    return delta
end

local function glossary_context_start(line)
    local _, _, name =
        find_code(strip_line_comment(line), "#let%s+([%a_][%w_%-]*)%s*=")
    return name and looks_like_glossary_name(name)
end

local function add_glossary_entry(path, row, col, name, out, seen)
    name = trim(name)
    if not name or glossary_entry_fields[name:lower()] then
        return
    end

    add_unique(out.glossary_entries, seen.glossary_entries, name, {
        name = name,
        kind = "glossary",
        source = source_location(path, row, col),
    })
end

function M.scan(path, row, line, out, seen, state)
    local code_line = strip_line_comment(line)
    if glossary_context_start(line) and not state.active then
        state.active = true
        state.depth = 0
    end

    if state.active then
        local key_start, _, key = code_line:find('key%s*:%s*"([^"]+)"')
        if key then
            add_glossary_entry(path, row, key_start, key, out, seen)
        end

        local bare_key_start, _, bare_key =
            code_line:find("key%s*:%s*([%w_.:/%-]+)")
        if bare_key then
            add_glossary_entry(path, row, bare_key_start, bare_key, out, seen)
        end

        local search_at = 1
        while true do
            local start_col, end_col, quoted_key =
                code_line:find('"([^"]+)"%s*:', search_at)
            if not start_col then
                break
            end
            add_glossary_entry(path, row, start_col, quoted_key, out, seen)
            search_at = end_col + 1
        end

        search_at = 1
        while true do
            local start_col, end_col, dict_key =
                code_line:find("([%w_.:/%-]+)%s*:%s*[%(%[%{]", search_at)
            if not start_col then
                break
            end
            add_glossary_entry(path, row, start_col, dict_key, out, seen)
            search_at = end_col + 1
        end
    end

    if state.active then
        state.depth = state.depth + delimiter_delta(line)
        if state.depth <= 0 then
            state.active = false
            state.depth = 0
        end
    end
end

return M
