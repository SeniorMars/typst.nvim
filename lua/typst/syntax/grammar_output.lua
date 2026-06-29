local util = require("typst.core.util")

local M = {}

local function clean_message(message)
    message = tostring(message or "")
    message = message:gsub("[\r\n]+", " ")
    message = message:gsub("%s+", " ")
    message = message:gsub("^%s+", ""):gsub("%s+$", "")
    return message
end

local function xml_unescape(text)
    text = tostring(text or "")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&apos;", "'")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&amp;", "&")
    return text
end

local function normalized_line(file, lnum, col, level, message)
    file = file and tostring(file):gsub("^%s+", ""):gsub("%s+$", "") or ""
    if file == "" then
        return nil
    end

    message = clean_message(message)
    if message == "" then
        return nil
    end

    return ("%s:%d:%d: %s: %s"):format(
        file,
        math.max(tonumber(lnum) or 1, 1),
        math.max(tonumber(col) or 1, 1),
        clean_message(level ~= "" and level or "warning"),
        message
    )
end

local function message_with_optional_level(rest, default_level)
    local level, message = tostring(rest or ""):match("^(%a+):%s*(.*)$")
    if level then
        return level, message
    end

    return default_level or "warning", rest
end

local function normalize_textidote_output(output, default_file)
    local normalized = {}

    for attributes in (output or ""):gmatch("<error%s+([^>]-)/?>") do
        local attrs = {}
        for key, quote, value in
            attributes:gmatch("([%w_:-]+)%s*=%s*([\"'])(.-)%2")
        do
            attrs[key:lower()] = xml_unescape(value)
        end

        local lnum = attrs.fromline or attrs.line or attrs.linenumber
        local col = attrs.fromcol or attrs.column or attrs.col or 1
        local message = attrs.msg
            or attrs.message
            or attrs.text
            or attrs.description
        local level = attrs.type or attrs.severity or attrs.level or "warning"
        local file = attrs.file or attrs.filename or attrs.path or default_file
        local line = normalized_line(file, lnum, col, level, message)
        if line then
            normalized[#normalized + 1] = line
        end
    end

    for _, line in ipairs(util.split_lines(output or "")) do
        local file, lnum, col, rest =
            line:match("^%s*(.-)%s*%([Ll](%d+)[Cc](%d+).-%)%s*:%s*(.*)$")
        if not file then
            file, lnum, col, rest =
                line:match("^%s*(.-)%s+[Ll](%d+)[Cc](%d+)%s*%-?.-:%s*(.*)$")
        end
        if not file then
            lnum, col, rest =
                line:match("^%s*[Ll](%d+)[Cc](%d+)%s*%-?.-:%s*(.*)$")
            file = lnum and default_file or nil
        end
        if not file then
            lnum, col, rest = line:match(
                "^%s*[Ll]ine%s+(%d+),?%s*[Cc]olumn%s+(%d+)%s*[:%-]%s*(.*)$"
            )
            file = lnum and default_file or nil
        end
        if not file then
            lnum, col, rest = line:match(
                "^%s*[Ll]ine%s+(%d+),?%s*[Cc]ol%s+(%d+)%s*[:%-]%s*(.*)$"
            )
            file = lnum and default_file or nil
        end

        if file then
            file = file:gsub("[%s:]+$", "")
            if file == "" then
                file = default_file
            end
            local level, message = message_with_optional_level(rest, "warning")
            local normalized_textidote =
                normalized_line(file, lnum, col, level, message)
            if normalized_textidote then
                normalized[#normalized + 1] = normalized_textidote
            end
        end
    end

    if #normalized > 0 then
        return table.concat(normalized, "\n")
    end

    return nil
end

local function decode_json(text)
    if type(text) ~= "string" or not text:match("^%s*[%[{]") then
        return nil
    end

    if vim.json and vim.json.decode then
        local ok, decoded = pcall(vim.json.decode, text)
        if ok then
            return decoded
        end
    end

    local ok, decoded = pcall(vim.fn.json_decode, text)
    if ok then
        return decoded
    end

    return nil
end

local function append_json_diagnostic(
    normalized,
    entry,
    default_file,
    mapped_file
)
    if type(entry) ~= "table" then
        return
    end

    local file = entry.file
        or entry.filename
        or entry.path
        or mapped_file
        or default_file
    local lnum = entry.line
        or entry.Line
        or entry.lnum
        or entry.startLine
        or entry.start_line
    local col = entry.column
        or entry.Column
        or entry.col
        or entry.startColumn
        or entry.start_column
    if col == nil and type(entry.Span) == "table" then
        col = entry.Span[1]
    end
    col = col or 1

    local message = entry.message
        or entry.Message
        or entry.description
        or entry.Description
        or entry.reason
    local check = entry.check or entry.Check or entry.rule or entry.Rule
    if check and message then
        message = ("%s: %s"):format(check, message)
    end
    local level = entry.severity
        or entry.Severity
        or entry.level
        or entry.Level
        or "warning"

    local line = normalized_line(file, lnum, col, level, message)
    if line then
        normalized[#normalized + 1] = line
    end
end

local function collect_json_diagnostics(
    value,
    normalized,
    default_file,
    mapped_file
)
    if type(value) ~= "table" then
        return
    end

    if value.diagnostics then
        collect_json_diagnostics(
            value.diagnostics,
            normalized,
            default_file,
            mapped_file
        )
        return
    end
    if value.matches then
        collect_json_diagnostics(
            value.matches,
            normalized,
            default_file,
            mapped_file
        )
        return
    end

    if util.is_list(value) then
        for _, entry in ipairs(value) do
            append_json_diagnostic(normalized, entry, default_file, mapped_file)
        end
        return
    end

    append_json_diagnostic(normalized, value, default_file, mapped_file)
    for key, entries in pairs(value) do
        if type(entries) == "table" and type(key) == "string" then
            collect_json_diagnostics(entries, normalized, default_file, key)
        end
    end
end

local function normalize_json_output(output, default_file)
    local decoded = decode_json(output)
    if not decoded then
        return nil
    end

    local normalized = {}
    collect_json_diagnostics(decoded, normalized, default_file, nil)
    if #normalized > 0 then
        return table.concat(normalized, "\n")
    end

    return nil
end

function M.normalize(output, opts)
    opts = opts or {}
    local provider_name = opts.parser or opts.provider
    if provider_name == "textidote" then
        local parsed = normalize_textidote_output(output, opts.default_file)
        if parsed then
            return parsed
        end
    elseif provider_name == "vlty" then
        local parsed = normalize_json_output(output, opts.default_file)
        if parsed then
            return parsed
        end
    end

    local parsed_json = normalize_json_output(output, opts.default_file)
    if parsed_json then
        return parsed_json
    end

    local normalized = {}

    for _, line in ipairs(util.split_lines(output or "")) do
        if line:match("^.-:%d+:%d+:%s*") then
            normalized[#normalized + 1] = line
        else
            local file, lnum, col, level, message =
                line:match("^(.-)%((%d+),(%d+)%)%:%s*(%a+)%:%s*(.*)$")
            if not file then
                file, lnum, col, message =
                    line:match("^(.-)%((%d+),(%d+)%)%:%s*(.*)$")
                level = "warning"
            end
            if not file then
                file, lnum, col, level, message = line:match(
                    "^(.-)%([Ll](%d+)[Cc](%d+).-%)%:%s*(%a+)%:%s*(.*)$"
                )
            end
            if not file then
                file, lnum, col, message =
                    line:match("^(.-)%([Ll](%d+)[Cc](%d+).-%)%:%s*(.*)$")
                level = "warning"
            end

            if file then
                normalized[#normalized + 1] = ("%s:%d:%d: %s: %s"):format(
                    file,
                    tonumber(lnum),
                    tonumber(col),
                    level,
                    message
                )
            else
                normalized[#normalized + 1] = line
            end
        end
    end

    return table.concat(normalized, "\n")
end

return M
