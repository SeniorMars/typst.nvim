local aggregate = require("typst.project.aggregate")
local heading_scanner = require("typst.project.headings")
local index_files = require("typst.project.index_files")
local index_paths = require("typst.project.index_paths")
local scanner_glossary = require("typst.project.scanner_glossary")
local scanner_helpers = require("typst.project.scanner_helpers")

local M = {}

local read_lines = index_files.read_lines
local add_unique = scanner_helpers.add_unique
local source_location = scanner_helpers.source_location
local parse_function_parameters = scanner_helpers.parse_function_parameters
local declaration_group_from_lines =
    scanner_helpers.declaration_group_from_lines
local enclosing_call_name = scanner_helpers.enclosing_call_name
local quoted_ranges = scanner_helpers.quoted_ranges
local in_ranges = scanner_helpers.in_ranges
local line_comment_start = scanner_helpers.line_comment_start
local strip_line_comment = scanner_helpers.strip_line_comment
local scrub_non_code_regions = scanner_helpers.scrub_non_code_regions
local find_code = scanner_helpers.find_code
local path_scan_helpers = scanner_helpers.path_scan_helpers()

-- Static Typst scanner for the project index. It intentionally uses bounded
-- textual heuristics instead of invoking Typst so navigation and completion work
-- without a successful compile.

local function identifier_char(char)
    return char ~= "" and char:match("[%w_%.%-]") ~= nil
end

local function find_named_call(line, name, search_at)
    search_at = search_at or 1
    local pattern = "#?" .. name .. "%s*%("
    while true do
        local start_col, end_col = find_code(line, pattern, search_at)
        if not start_col then
            return nil
        end

        local previous = line:sub(start_col - 1, start_col - 1)
        if not identifier_char(previous) then
            return start_col, end_col
        end

        search_at = math.max(end_col + 1, start_col + 1)
    end
end

local function call_text_from_lines(lines, row, start_col)
    local parts = {}
    local depth = 0
    local saw_open = false
    local quote = nil
    local escaped = false
    -- Function-style references can span lines, but scanning arbitrarily far
    -- would make one malformed call poison the whole file scan.
    local max_row = math.min(#lines, row + 50)

    for next_row = row, max_row do
        local segment = strip_line_comment(lines[next_row] or "")
        if next_row == row then
            segment = segment:sub(start_col)
        end
        parts[#parts + 1] = segment

        for index = 1, #segment do
            local char = segment:sub(index, index)
            if quote then
                if escaped then
                    escaped = false
                elseif char == "\\" then
                    escaped = true
                elseif char == quote then
                    quote = nil
                end
            elseif char == '"' then
                quote = char
            elseif char == "(" then
                depth = depth + 1
                saw_open = true
            elseif char == ")" then
                if depth > 0 then
                    depth = depth - 1
                end
                if saw_open and depth == 0 then
                    return table.concat(parts, "\n")
                end
            end
        end
    end

    return table.concat(parts, "\n")
end

local function top_level_label_arguments(call_text)
    local labels = {}
    local open = call_text:find("(", 1, true)
    if not open then
        return labels
    end

    local argument_start = open + 1
    local depth = 1
    local quote = nil
    local escaped = false

    local function add_argument(stop)
        local text = call_text:sub(argument_start, stop)
        local leading = text:match("^%s*") or ""
        local trailing = text:match("%s*$") or ""
        local trimmed = text:sub(#leading + 1, #text - #trailing)
        local name = trimmed:match("^<([^%s<>]+)>$")
        if name then
            labels[#labels + 1] = {
                name = name,
                offset = argument_start + #leading,
            }
        end
    end

    for index = open + 1, #call_text do
        local char = call_text:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
            end
        elseif char == '"' then
            quote = char
        elseif char == "(" or char == "[" or char == "{" then
            depth = depth + 1
        elseif char == ")" or char == "]" or char == "}" then
            depth = depth - 1
            if depth == 0 then
                add_argument(index - 1)
                break
            end
        elseif char == "," and depth == 1 then
            add_argument(index - 1)
            argument_start = index + 1
        end
    end

    return labels
end

local function call_offset_source_position(
    call_text,
    start_row,
    start_col,
    offset
)
    local row = start_row
    local line_start = 1

    while true do
        local newline = call_text:find("\n", line_start, true)
        if not newline or newline >= offset then
            if row == start_row then
                return row, start_col + offset - line_start
            end
            return row, offset - line_start + 1
        end

        row = row + 1
        line_start = newline + 1
    end
end

local function mark_call_ranges(ranges_by_row, start_row, start_col, call_text)
    local row = start_row
    local line_start = 1

    while true do
        local newline = call_text:find("\n", line_start, true)
        local range_start = row == start_row and start_col or 1
        local range_end
        if newline then
            range_end = range_start + newline - line_start - 1
        else
            range_end = range_start + #call_text - line_start
        end

        ranges_by_row[row] = ranges_by_row[row] or {}
        ranges_by_row[row][#ranges_by_row[row] + 1] = {
            range_start,
            math.max(range_start, range_end),
            "reference_call",
        }

        if not newline then
            break
        end
        row = row + 1
        line_start = newline + 1
    end
end

local function reference_call_ranges(lines)
    local ranges_by_row = {}
    for row, line in ipairs(lines or {}) do
        for _, pattern in ipairs({ "#?cite%s*%(", "#?ref%s*%(" }) do
            local search_at = 1
            while true do
                local name = pattern:match("([%a_]+)")
                local start_col, end_col =
                    find_named_call(line, name, search_at)
                if not start_col then
                    break
                end

                mark_call_ranges(
                    ranges_by_row,
                    row,
                    start_col,
                    call_text_from_lines(lines, row, start_col)
                )
                search_at = end_col + 1
            end
        end
    end
    return ranges_by_row
end

local function add_reference(out, seen, path, row, col, name, style)
    add_unique(
        out.references,
        seen.references,
        ("%s\n%d\n%d\n%s"):format(path, row, col, style or "shorthand"),
        {
            name = name,
            kind = "reference",
            reference_style = style or "shorthand",
            source = source_location(path, row, col),
        }
    )
end

local function scan_labels(path, row, line, out, seen, reference_ranges)
    local ranges = quoted_ranges(line)
    local search_at = 1
    while true do
        local start_col, end_col, name = line:find("<([^%s<>]+)>", search_at)
        if not start_col then
            break
        end

        local prefix = line:sub(1, start_col - 1)
        local call = enclosing_call_name(prefix)
        if
            call ~= "cite"
            and call ~= "ref"
            and not in_ranges(start_col, ranges)
            and not in_ranges(start_col, reference_ranges)
        then
            add_unique(out.labels, seen.labels, name, {
                name = name,
                kind = "label",
                source = source_location(path, row, start_col),
            })
        end

        search_at = end_col + 1
    end
end

local function scan_label_call_references(
    path,
    row,
    line,
    lines,
    out,
    seen,
    ranges,
    call_name,
    style,
    first_only
)
    local search_at = 1
    while true do
        local start_col, end_col = find_named_call(line, call_name, search_at)
        if not start_col then
            break
        end

        if not in_ranges(start_col, ranges) then
            local call_text = call_text_from_lines(lines or {}, row, start_col)
            for _, label in ipairs(top_level_label_arguments(call_text)) do
                local source_row, source_col = call_offset_source_position(
                    call_text,
                    row,
                    start_col,
                    label.offset
                )
                add_reference(
                    out,
                    seen,
                    path,
                    source_row,
                    source_col,
                    label.name,
                    style
                )
                if first_only then
                    break
                end
            end
        end

        search_at = end_col + 1
    end
end

local function scan_references(path, row, line, lines, out, seen)
    local ranges = quoted_ranges(line)
    local search_at = 1
    while true do
        local start_col, end_col, name = line:find("@([%w_.:/%-]+)", search_at)
        if not start_col then
            break
        end

        if not in_ranges(start_col, ranges) then
            add_reference(out, seen, path, row, start_col, name, "shorthand")
        end
        search_at = end_col + 1
    end

    scan_label_call_references(
        path,
        row,
        line,
        lines,
        out,
        seen,
        ranges,
        "ref",
        "function",
        true
    )
    scan_label_call_references(
        path,
        row,
        line,
        lines,
        out,
        seen,
        ranges,
        "cite",
        "cite",
        false
    )
end

local function scan_definition(path, row, line, lines, out, seen)
    local code_line = strip_line_comment(line)
    local start_col, end_col, name =
        find_code(code_line, "#let%s+([%a_][%w_%-]*)")
    if not name then
        return
    end

    local group = declaration_group_from_lines(lines, row, code_line, end_col)
    local kind = group and "function" or "local"
    local item = {
        name = name,
        kind = kind,
        signature = group and (name .. group) or name,
        parameters = group and parse_function_parameters(group) or {},
        source = source_location(path, row, start_col),
    }
    add_unique(out.definitions, seen.definitions, path .. "\n" .. name, item)
    out.definitions_by_file[path] = out.definitions_by_file[path] or {}
    out.definitions_by_file[path][name] = item
end

local function scan_todo(path, row, line, out, seen)
    local comment_col = line_comment_start(line)
    if not comment_col then
        return
    end

    local _, _, tag, text = line:sub(comment_col)
        :find("//%s*([A-Z]+)[:%s]*(.*)")
    if not ({ TODO = true, FIXME = true, NOTE = true, WARN = true })[tag] then
        return
    end

    local key = ("%s\n%d\n%s"):format(path, row, tag)
    add_unique(out.todos, seen.todos, key, {
        tag = tag,
        text = vim.trim(text or ""),
        kind = "todo",
        source = source_location(path, row, comment_col),
    })
end

local function scan_structures(path, row, line, out, seen)
    local code_line = strip_line_comment(line)
    local figure_col = find_code(code_line, "#figure", 1, true)
    if figure_col then
        add_unique(
            out.figures,
            seen.figures,
            path .. "\n" .. row .. "\nfigure",
            {
                name = "figure",
                kind = "figure",
                source = source_location(path, row, figure_col),
            }
        )
    end

    local table_col = find_code(code_line, "#table", 1, true)
    if table_col then
        add_unique(out.tables, seen.tables, path .. "\n" .. row .. "\ntable", {
            name = "table",
            kind = "table",
            source = source_location(path, row, table_col),
        })
    end

    local equation_col = find_code(code_line, "$", 1, true)
    if equation_col then
        add_unique(
            out.equations,
            seen.equations,
            path .. "\n" .. row .. "\nequation",
            {
                name = "equation",
                kind = "equation",
                source = source_location(path, row, equation_col),
            }
        )
    end
end

local function scan_file(project, path, out, seen, queue, queued)
    local glossary_state = {
        active = false,
        depth = 0,
    }

    local lines = read_lines(project, path)
    -- Scan a scrubbed copy for syntax-like constructs so labels/references in
    -- comments, strings, and raw blocks do not enter the project index.
    local code_lines = scrub_non_code_regions(lines)
    local reference_ranges = reference_call_ranges(code_lines)
    heading_scanner.scan(project, path, lines, code_lines, out, seen)

    for row, line in ipairs(lines) do
        local code_line = code_lines[row] or line
        scan_labels(path, row, code_line, out, seen, reference_ranges[row])
        scan_references(path, row, code_line, code_lines, out, seen)
        scan_definition(path, row, code_line, code_lines, out, seen)
        scan_todo(path, row, code_line, out, seen)
        scanner_glossary.scan(path, row, code_line, out, seen, glossary_state)
        scan_structures(path, row, code_line, out, seen)
        index_paths.scan_imports(
            path,
            row,
            code_line,
            code_lines,
            out,
            seen,
            queue,
            queued,
            path_scan_helpers
        )
        index_paths.scan_includes(
            path,
            row,
            code_line,
            out,
            seen,
            queue,
            queued,
            path_scan_helpers
        )
        index_paths.scan_bibliography_paths(
            path,
            row,
            code_line,
            code_lines,
            out,
            path_scan_helpers
        )
        index_paths.scan_path_calls(
            path,
            row,
            code_line,
            code_lines,
            out,
            seen,
            path_scan_helpers
        )
    end
end

function M.scan_file_record(project, path)
    local out = aggregate.empty_collected(project)
    local seen = aggregate.empty_seen()
    local discovered = {}
    local discovered_seen = {}

    scan_file(project, path, out, seen, discovered, discovered_seen)
    return {
        path = path,
        data = out,
        imports = discovered,
    }
end

function M.scan_file_record_headings_only(project, path)
    local out = aggregate.empty_collected(project)
    local seen = aggregate.empty_seen()
    local discovered = {}
    local discovered_seen = {}

    local lines = read_lines(project, path)
    local code_lines = scrub_non_code_regions(lines)
    heading_scanner.scan(project, path, lines, code_lines, out, seen)

    for row, code_line in ipairs(code_lines) do
        index_paths.scan_imports(
            path,
            row,
            code_line,
            code_lines,
            out,
            seen,
            discovered,
            discovered_seen,
            path_scan_helpers
        )
        index_paths.scan_includes(
            path,
            row,
            code_line,
            out,
            seen,
            discovered,
            discovered_seen,
            path_scan_helpers
        )
    end

    return {
        path = path,
        data = out,
        imports = discovered,
        large_file_policy = "headings-only",
    }
end

return M
