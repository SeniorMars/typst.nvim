local lexical = require("typst.syntax.lexical")

local M = {}

local identifier_pattern = "[%a_][%w_%-]*"
local package_spec_pattern = "@[%w_%-]+/[%w_%-%.]+:[%w_%.%-%+]+"

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function token_on_line(line, row, col)
    for start_index, token, end_index in line:gmatch("()([%a_][%w_%.%-]*)()") do
        if start_index - 1 <= col and col <= end_index - 1 then
            return token,
                {
                    start_row = row,
                    start_col = start_index - 1,
                    end_row = row,
                    end_col = end_index - 1,
                }
        end
    end
end

local function package_on_line(line, row, col)
    for start_index, spec, end_index in
        line:gmatch("()(" .. package_spec_pattern .. ")()")
    do
        if start_index - 1 <= col and col <= end_index - 1 then
            return spec,
                {
                    start_row = row,
                    start_col = start_index - 1,
                    end_row = row,
                    end_col = end_index - 1,
                }
        end
    end
end

local function cursor_position(bufnr, winid)
    bufnr = normalize_bufnr(bufnr)
    winid = winid or vim.api.nvim_get_current_win()
    if
        not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    return cursor[1] - 1, cursor[2]
end

local function position_from_opts(bufnr, opts)
    if opts.pos then
        return opts.pos[1], opts.pos[2]
    end
    return cursor_position(bufnr, opts.winid)
end

local function line_at_position(bufnr, row)
    if not row then
        return nil
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return line
end

local function token_at_position(bufnr, opts)
    bufnr = normalize_bufnr(bufnr)
    local row, col = position_from_opts(bufnr, opts)
    local line = line_at_position(bufnr, row)
    if not line then
        return nil
    end
    return token_on_line(line, row, col)
end

local function package_at_position(bufnr, opts)
    bufnr = normalize_bufnr(bufnr)
    local row, col = position_from_opts(bufnr, opts)
    local line = line_at_position(bufnr, row)
    if not line then
        return nil
    end
    return package_on_line(line, row, col)
end

local function strip_comment(line)
    local in_single = false
    local in_double = false
    local escaped = false

    for index = 1, #line do
        local char = line:sub(index, index)
        if escaped then
            escaped = false
        elseif char == "\\" and in_double then
            escaped = true
        elseif char == "'" and not in_double then
            in_single = not in_single
        elseif char == '"' and not in_single then
            in_double = not in_double
        elseif
            char == "/"
            and not in_single
            and not in_double
            and lexical.is_line_comment_start(line, index)
        then
            return line:sub(1, index - 1)
        end
    end

    return line
end

local function package_name_from_spec(spec)
    return spec and spec:match("^@[%w_%-]+/([%w_%-%.]+):")
end

local function item_leaf(item)
    return item and item:match("(" .. identifier_pattern .. ")$")
end

local function valid_item_path(item)
    return item
        and item:match(
                "^"
                    .. identifier_pattern
                    .. "(%."
                    .. identifier_pattern
                    .. ")*$"
            )
            ~= nil
end

local function remember_member(imports, spec, exported, alias)
    if not valid_item_path(exported) then
        return
    end

    local local_name = alias or item_leaf(exported)
    if not local_name then
        return
    end

    local record = {
        spec = spec,
        member = exported,
        local_name = local_name,
    }
    imports.members[local_name] = record
    if exported:find(".", 1, true) and not imports.members[exported] then
        imports.members[exported] = record
    end
end

local function parse_member_list(imports, spec, members)
    members = trim(members)
    if not members then
        return
    end

    members = members:gsub("^%(%s*", ""):gsub("%s*%)$", "")
    for item in members:gmatch("([^,]+)") do
        item = vim.trim(item)
        if item == "*" then
            imports.wildcards[#imports.wildcards + 1] = {
                spec = spec,
            }
        else
            local exported, alias = item:match(
                "^("
                    .. identifier_pattern
                    .. "[%w_%-%.]*)%s+as%s+("
                    .. identifier_pattern
                    .. ")$"
            )
            exported = exported
                or item:match("^(" .. identifier_pattern .. "[%w_%-%.]*)$")
            remember_member(imports, spec, exported, alias)
        end
    end
end

local function parse_package_imports(bufnr)
    local imports = {
        aliases = {},
        members = {},
        wildcards = {},
    }

    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        line = strip_comment(line)
        local spec, tail = line:match(
            "#import%s+[\"'](" .. package_spec_pattern .. ")[\"']%s*(.*)$"
        )
        if spec then
            tail = vim.trim(tail or "")
            local members = tail:match("^:%s*(.+)$")
            local alias = tail:match("^as%s+(" .. identifier_pattern .. ")$")
            if members then
                parse_member_list(imports, spec, members)
            elseif alias then
                imports.aliases[alias] = {
                    spec = spec,
                    alias = alias,
                }
            elseif tail == "" then
                local package_name = package_name_from_spec(spec)
                if package_name then
                    imports.aliases[package_name] = {
                        spec = spec,
                        alias = package_name,
                    }
                end
            end
        else
            local module_alias, members = line:match(
                "#import%s+(" .. identifier_pattern .. ")%s*:%s*(.+)$"
            )
            local alias_record = module_alias and imports.aliases[module_alias]
            if alias_record then
                parse_member_list(imports, alias_record.spec, members)
            end
        end
    end

    return imports
end

local function package_member_context(bufnr, token)
    local imports = parse_package_imports(bufnr)
    local alias, member = token:match("^([%a_][%w_%-]*)%.([%a_][%w_%-%.]*)$")
    if alias and member and imports.aliases[alias] then
        return {
            spec = imports.aliases[alias].spec,
            member = member,
            local_name = token,
            qualified_name = token,
        }
    end

    if imports.members[token] then
        return imports.members[token]
    end

    if #imports.wildcards == 1 then
        return {
            spec = imports.wildcards[1].spec,
            member = token,
            local_name = token,
        }
    end
end

function M.resolve(opts)
    opts = opts or {}
    local query = trim(opts.query)
    if query then
        return {
            query = query,
            source = "argument",
            bufnr = normalize_bufnr(opts.bufnr),
        }
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local package, package_range = package_at_position(bufnr, opts)
    package = trim(package)
    if package then
        return {
            kind = "package",
            query = package,
            source = "cursor",
            bufnr = bufnr,
            position = {
                buffer = bufnr,
                row = package_range.start_row,
                column = package_range.start_col,
            },
            range = package_range,
        }
    end

    local token, range = token_at_position(bufnr, opts)
    token = trim(token)
    if not token then
        return nil
    end

    local package_member = package_member_context(bufnr, token)
    if package_member then
        return {
            kind = "package_member",
            query = package_member.member,
            qualified_name = package_member.qualified_name
                or package_member.local_name
                or token,
            source = "cursor",
            bufnr = bufnr,
            package = {
                spec = package_member.spec,
            },
            position = {
                buffer = bufnr,
                row = range.start_row,
                column = range.start_col,
            },
            range = range,
        }
    end

    return {
        kind = "unknown",
        query = token,
        source = "cursor",
        bufnr = bufnr,
        position = {
            buffer = bufnr,
            row = range.start_row,
            column = range.start_col,
        },
        range = range,
    }
end

return M
