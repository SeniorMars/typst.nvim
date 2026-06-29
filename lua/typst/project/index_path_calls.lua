local util = require("typst.core.util")

local M = {}

local function call_text_from_lines(helpers, lines, row, start_col)
    local parts = {}
    local depth = 0
    local saw_open = false
    local quote = nil
    local escaped = false
    local max_row = math.min(#lines, row + 50)

    for next_row = row, max_row do
        local segment = helpers.strip_line_comment(lines[next_row] or "")
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

local function scan_named_calls(helpers, line, lines, row, names, callback)
    local code_line = helpers.strip_line_comment(line)
    for _, name in ipairs(names) do
        local search_at = 1
        while true do
            local start_col, end_col =
                helpers.find_code(code_line, name .. "%s*%(", search_at)
            if not start_col then
                break
            end

            callback(
                name,
                start_col,
                call_text_from_lines(helpers, lines or {}, row, start_col)
            )
            search_at = end_col + 1
        end
    end
end

function M.scan_bibliography_paths(path, row, line, lines, out, helpers)
    scan_named_calls(
        helpers,
        line,
        lines,
        row,
        { "bibliography" },
        function(_, _, call_text)
            local spec = call_text:match('bibliography%s*%(%s*"([^"]+)"')
            if not spec then
                return
            end

            local resolved = util.resolve_path(spec, util.dirname(path))
            out.bibliography_paths[resolved] = spec
        end
    )
end

local function add_path(
    helpers,
    out,
    seen,
    path,
    row,
    spec,
    path_kind,
    start_col
)
    local resolved = util.resolve_path(spec, util.dirname(path))
    helpers.add_unique(
        out.paths,
        seen.paths,
        ("%s\n%s\n%s"):format(spec, path, path_kind or "path"),
        {
            path = resolved,
            word = spec,
            kind = "path",
            path_kind = path_kind,
            source = helpers.source_location(path, row, start_col or 1),
        }
    )
    return resolved
end

local function scan_csl_style_paths(helpers, path, row, line, lines, out, seen)
    scan_named_calls(
        helpers,
        line,
        lines,
        row,
        { "bibliography", "cite" },
        function(_, start_col, call_text)
            local search_at = 1
            while true do
                local style_start, style_end, spec = helpers.find_code(
                    call_text,
                    'style%s*:%s*"([^"]+)"',
                    search_at
                )
                if not style_start then
                    break
                end

                local resolved = util.resolve_path(spec, util.dirname(path))
                if vim.fn.filereadable(resolved) == 1 then
                    helpers.add_unique(
                        out.paths,
                        seen.paths,
                        ("%s\n%s\ncsl_style"):format(spec, path),
                        {
                            path = resolved,
                            word = spec,
                            kind = "path",
                            path_kind = "csl_style",
                            source = helpers.source_location(
                                path,
                                row,
                                start_col + style_start - 1
                            ),
                        }
                    )
                end

                search_at = style_end + 1
            end
        end
    )
end

function M.scan_path_calls(path, row, line, lines, out, seen, helpers)
    scan_named_calls(
        helpers,
        line,
        lines,
        row,
        { "include", "image", "read", "bibliography" },
        function(name, start_col, call_text)
            local search_at = 1
            while true do
                local spec_start, spec_end, spec = helpers.find_code(
                    call_text,
                    name .. '%s*%(%s*"([^"]+)"',
                    search_at
                )
                if not spec_start then
                    break
                end

                add_path(
                    helpers,
                    out,
                    seen,
                    path,
                    row,
                    spec,
                    name,
                    start_col + spec_start - 1
                )
                search_at = spec_end + 1
            end
        end
    )

    scan_csl_style_paths(helpers, path, row, line, lines, out, seen)
end

return M
