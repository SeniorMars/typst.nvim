local lexer = require("typst.bibliography.bibtex_lexer")
local values = require("typst.bibliography.bibtex_values")

local M = {}

local function parse_fields(text, index, stop, macros)
    local fields = {}

    while index <= stop do
        index = lexer.skip_space_and_comments(text, index, stop)
        while text:sub(index, index) == "," do
            index = lexer.skip_space_and_comments(text, index + 1, stop)
        end

        local name_start, name_end, name = text:find("^([%a][%w_%-]*)", index)
        if not name then
            break
        end

        index = lexer.skip_space(text, name_end + 1, stop)
        if text:sub(index, index) ~= "=" then
            index = name_end + 1
        else
            index = lexer.skip_space(text, index + 1, stop)
            local value_end, next_index =
                lexer.field_value_end(text, index, stop)
            local value = values.clean(text:sub(index, value_end), macros)
            if value then
                fields[name:lower()] = value
            end
            index = next_index
        end

        if name_start <= index then
            index = math.max(index, name_start + 1)
        end
    end

    return fields
end

local function string_macro_assignment(text, index, stop)
    index = lexer.skip_space(text, index, stop)
    local name_start, name_end, name = text:find("^([%a][%w_%-]*)", index)
    if not name then
        return nil, nil
    end

    index = lexer.skip_space(text, name_end + 1, stop)
    if text:sub(index, index) ~= "=" then
        return nil, nil
    end

    index = lexer.skip_space(text, index + 1, stop)
    local value_end = lexer.field_value_end(text, index, stop)
    if not value_end or value_end < index then
        return nil, nil
    end

    return name:lower(), text:sub(index, value_end)
end

function M.parse_bibtex_lines(lines)
    lines = lines or {}
    local text = table.concat(lexer.scrub_comments(lines), "\n")
    local offsets = lexer.line_offsets(lines)
    local raw_entries = {}
    local raw_macros = {}
    local index = 1
    local stop = #text

    while index <= stop do
        local at_start, at_end, entry_type =
            text:find("@%s*([%a][%w_%-]*)", index)
        if not at_start then
            break
        end

        local open_index = lexer.skip_space(text, at_end + 1, stop)
        local open = text:sub(open_index, open_index)
        if open ~= "{" and open ~= "(" then
            index = at_end + 1
        else
            local close_index = lexer.find_matching(
                text,
                open_index,
                stop,
                open,
                lexer.matching_close(open)
            )
            if not close_index then
                break
            end

            local lower_type = entry_type:lower()
            if lower_type == "string" then
                local name, value = string_macro_assignment(
                    text,
                    open_index + 1,
                    close_index - 1
                )
                if name and value then
                    raw_macros[name] = value
                end
            elseif lower_type ~= "comment" and lower_type ~= "preamble" then
                local key_start =
                    lexer.skip_space(text, open_index + 1, close_index - 1)
                local key_end = text:find(",", key_start, true)
                if key_end and key_end < close_index then
                    local key = vim.trim(text:sub(key_start, key_end - 1))
                    if key ~= "" then
                        local lnum, col =
                            lexer.offset_position(offsets, key_start)
                        raw_entries[#raw_entries + 1] = {
                            type = lower_type,
                            key = key,
                            lnum = lnum,
                            col = col,
                            fields_start = key_end + 1,
                            fields_stop = close_index - 1,
                        }
                    end
                end
            end

            index = close_index + 1
        end
    end

    local macros = values.resolve_macros(raw_macros)
    local entries = {}
    for _, entry in ipairs(raw_entries) do
        entries[#entries + 1] = {
            type = entry.type,
            key = entry.key,
            lnum = entry.lnum,
            col = entry.col,
            fields = parse_fields(
                text,
                entry.fields_start,
                entry.fields_stop,
                macros
            ),
        }
    end

    return entries
end

function M.parse_bibtex_file(path)
    return M.parse_bibtex_lines(lexer.read_lines(path))
end

function M.bibtex_entry(path, key, lnum)
    for _, entry in ipairs(M.parse_bibtex_file(path)) do
        if key and entry.key == key then
            return entry
        end
        if lnum and entry.lnum == lnum then
            return entry
        end
    end
end

function M.bibtex_fields(path, key, lnum)
    local entry = M.bibtex_entry(path, key, lnum)
    return entry and entry.fields or {}
end

return M
