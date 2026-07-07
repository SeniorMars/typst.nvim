local util = require("typst.core.util")
local path_calls = require("typst.project.index_path_calls")

local M = {}

local function split_import_members(helpers, text)
    local members = {}
    for part in (text or ""):gmatch("[^,]+") do
        part = helpers.trim(part)
        if part then
            if part == "*" then
                members[#members + 1] = { wildcard = true }
            else
                local name, alias =
                    part:match("^([%w_%.%-]+)%s+as%s+([%w_%-]+)$")
                if name then
                    members[#members + 1] = { name = name, alias = alias }
                else
                    members[#members + 1] = { name = part, alias = part }
                end
            end
        end
    end
    return members
end

local function add_wildcard_import(
    helpers,
    path,
    row,
    line,
    spec,
    resolved,
    out,
    seen
)
    helpers.add_unique(
        out.wildcard_imports,
        seen.wildcard_imports,
        spec .. "\n" .. path,
        {
            spec = spec,
            path = resolved,
            kind = "wildcard_import",
            source = helpers.source_location(
                path,
                row,
                line:find("*", 1, true) or line:find("#import", 1, true) or 1
            ),
        }
    )
end

local function add_import_member(
    helpers,
    path,
    row,
    line,
    spec,
    resolved,
    member,
    out,
    seen
)
    helpers.add_unique(
        out.imported_bindings,
        seen.imported_bindings,
        member.alias,
        {
            name = member.alias,
            imported_name = member.name,
            spec = spec,
            path = resolved,
            kind = "import",
            source = helpers.source_location(
                path,
                row,
                line:find(member.alias, 1, true) or 1
            ),
        }
    )
end

local function add_import_members(
    helpers,
    path,
    row,
    line,
    spec,
    resolved,
    member_text,
    out,
    seen
)
    for _, member in ipairs(split_import_members(helpers, member_text)) do
        if member.wildcard then
            add_wildcard_import(
                helpers,
                path,
                row,
                line,
                spec,
                resolved,
                out,
                seen
            )
        else
            add_import_member(
                helpers,
                path,
                row,
                line,
                spec,
                resolved,
                member,
                out,
                seen
            )
        end
    end
end

local function resolve_local_import(spec, base)
    if spec:sub(1, 1) == "@" then
        return nil
    end

    return util.resolve_path(spec, base)
end

local function queue_local_typst_file(resolved, queue, queued)
    if
        resolved
        and resolved:match("%.typ$")
        and vim.fn.filereadable(resolved) == 1
        and not queued[resolved]
    then
        queued[resolved] = true
        queue[#queue + 1] = resolved
    end
end

local function import_selector_line(helpers, line)
    line = helpers.trim(helpers.strip_line_comment(line or ""))
    if not line then
        return nil, false
    end

    local trailing = line:match(",%s*$") ~= nil
    local value = helpers.trim(trailing and line:gsub(",%s*$", "") or line)
    if not value then
        return nil, false
    end

    if
        value == "*"
        or value:match("^[%w_%.%-]+$")
        or value:match("^[%w_%.%-]+%s+as%s+[%w_%-]+$")
    then
        return value .. (trailing and "," or ""), trailing
    end

    return nil, false
end

local function extend_import_suffix(helpers, lines, row, suffix)
    local member_text = suffix:match("^%s*:%s*(.*)")
    if member_text == nil then
        return suffix
    end

    if member_text ~= "" and not member_text:match(",%s*$") then
        return suffix
    end

    local parts = {}
    local max_row = math.min(#lines, row + 20)
    for next_row = row + 1, max_row do
        local value, trailing = import_selector_line(helpers, lines[next_row])
        if not value then
            break
        end

        parts[#parts + 1] = value
        if not trailing then
            break
        end
    end

    if #parts == 0 then
        return suffix
    end

    return suffix .. "\n" .. table.concat(parts, "\n")
end

function M.scan_imports(
    path,
    row,
    line,
    lines,
    out,
    seen,
    queue,
    queued,
    helpers
)
    local code_line = helpers.strip_line_comment(line)
    local start_col, _, spec, suffix =
        helpers.find_code(code_line, '#import%s+"([^"]+)"%s*(.*)')
    if not spec then
        return
    end

    suffix = extend_import_suffix(helpers, lines or {}, row, suffix or "")
    local resolved = resolve_local_import(spec, util.dirname(path))
    helpers.add_unique(out.imports, seen.imports, spec .. "\n" .. path, {
        spec = spec,
        path = resolved,
        kind = spec:sub(1, 1) == "@" and "package" or "file",
        source = helpers.source_location(
            path,
            row,
            start_col or line:find("#import", 1, true) or 1
        ),
    })
    queue_local_typst_file(resolved, queue, queued)

    local alias = suffix:match("^%s*as%s+([%w_%-]+)")
    if alias then
        helpers.add_unique(out.module_aliases, seen.module_aliases, alias, {
            name = alias,
            spec = spec,
            path = resolved,
            kind = "module",
            source = helpers.source_location(
                path,
                row,
                line:find(alias, 1, true) or 1
            ),
        })
    end

    local member_text = suffix:match("^%s*:%s*(.+)")
    add_import_members(
        helpers,
        path,
        row,
        line,
        spec,
        resolved,
        member_text,
        out,
        seen
    )
end

function M.scan_includes(path, row, line, out, seen, queue, queued, helpers)
    local code_line = helpers.strip_line_comment(line)

    local function scan_pattern(pattern)
        local search_at = 1
        while true do
            local start_col, end_col, spec =
                helpers.find_code(code_line, pattern, search_at)
            if not start_col then
                break
            end

            local resolved = resolve_local_import(spec, util.dirname(path))
            helpers.add_unique(
                out.paths,
                seen.paths,
                spec .. "\n" .. path .. "\ninclude",
                {
                    path = resolved,
                    word = spec,
                    kind = "path",
                    path_kind = "include",
                    source = helpers.source_location(
                        path,
                        row,
                        line:find(spec, start_col, true) or start_col
                    ),
                }
            )
            queue_local_typst_file(resolved, queue, queued)
            search_at = end_col + 1
        end
    end

    scan_pattern('#include%s*"([^"]+)"')
end

M.scan_bibliography_paths = path_calls.scan_bibliography_paths
M.scan_path_calls = path_calls.scan_path_calls

return M
