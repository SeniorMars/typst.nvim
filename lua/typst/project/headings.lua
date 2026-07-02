local index_files = require("typst.project.index.files")

local M = {}

local buffer_for_file = index_files.buffer_for_file
local buffer_path = index_files.buffer_path
local initial_files = index_files.initial_files
local parse_buffer_for_lines = index_files.parse_buffer_for_lines

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

local function heading_title_text(value)
    value = trim(value)
    if not value then
        return nil
    end

    repeat
        local next_value, count = value:gsub("%s*<[^%s<>]+>%s*$", "")
        value = vim.trim(next_value)
    until count == 0

    return trim(value)
end

local function source_location(path, row, col)
    return {
        path = path,
        lnum = row,
        col = col or 1,
    }
end

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

local function add_heading(out, seen, path, row, col, level, title, source)
    title = heading_title_text(title)
    if not title then
        return
    end

    add_unique(
        out.headings,
        seen.headings,
        ("%s\n%d\n%d\n%s"):format(path, row, col or 1, title),
        {
            name = title,
            title = title,
            kind = "heading",
            level = level or 1,
            source = source_location(path, row, col or 1),
            source_kind = source,
        }
    )
end

local function heading_title(bufnr, heading)
    for child in heading:iter_children() do
        if child:type() == "text" then
            return vim.trim(vim.treesitter.get_node_text(child, bufnr))
        end
    end

    local text = vim.treesitter.get_node_text(heading, bufnr)
    return vim.trim(text:gsub("^=+%s*", ""))
end

local function heading_level(bufnr, heading)
    local text = vim.treesitter.get_node_text(heading, bufnr)
    local marker = text:match("^(=+)")
    return marker and #marker or 1
end

local function scan_treesitter(project, path, lines, out, seen)
    local bufnr = buffer_for_file(project, path)
    local temporary = false
    if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
        bufnr = parse_buffer_for_lines(lines)
        temporary = true
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    if not ok or not parser then
        if temporary then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        return false
    end

    local parsed_ok, trees = pcall(parser.parse, parser)
    if not parsed_ok or not trees or not trees[1] then
        if temporary then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        return false
    end

    local function walk(node)
        if node:type() == "heading" then
            local row, col = node:range()
            add_heading(
                out,
                seen,
                path,
                row + 1,
                col + 1,
                heading_level(bufnr, node),
                heading_title(bufnr, node),
                "treesitter"
            )
            return
        end

        for child in node:iter_children() do
            walk(child)
        end
    end

    walk(trees[1]:root())
    if temporary then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    return true
end

local function scan_lines(path, lines, out, seen)
    for row, line in ipairs(lines) do
        local marker, title = line:match("^(=+)%s+(.+)$")
        if marker then
            add_heading(out, seen, path, row, 1, #marker, title, "line")
        end
    end
end

function M.scan(project, path, lines, code_lines, out, seen)
    if not scan_treesitter(project, path, lines, out, seen) then
        scan_lines(path, code_lines or lines, out, seen)
    end
end

function M.semantic_helpers()
    return {
        add_heading = add_heading,
        buffer_for_file = buffer_for_file,
        buffer_path = buffer_path,
        initial_files = initial_files,
    }
end

return M
