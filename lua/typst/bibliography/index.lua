local parser = require("typst.bibliography.parser")

local M = {}

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

local function source_location(path, row, col)
    return {
        path = path,
        lnum = row,
        col = col or 1,
    }
end

local function empty_collected(project)
    return {
        project = project,
        citations = {},
        all_citations = {},
    }
end

local function scan_bibtex(path, out, seen)
    for _, entry in ipairs(parser.parse_bibtex_file(path)) do
        local item = {
            name = entry.key,
            kind = "citation",
            source = source_location(path, entry.lnum, entry.col),
            fields = vim.deepcopy(entry.fields or {}),
        }
        out.all_citations[#out.all_citations + 1] = vim.deepcopy(item)
        add_unique(out.citations, seen.citations, entry.key, item)
    end
end

local function scan_hayagriva(path, out, seen)
    for _, entry in ipairs(parser.parse_hayagriva_file(path)) do
        local item = {
            name = entry.key,
            kind = "citation",
            source = source_location(path, entry.lnum, entry.col),
            fields = vim.deepcopy(entry.fields or {}),
        }
        out.all_citations[#out.all_citations + 1] = vim.deepcopy(item)
        add_unique(out.citations, seen.citations, entry.key, item)
    end
end

--- Scan one bibliography file into project-index citation records.
---@param path string Bibliography file path, either BibTeX or Hayagriva YAML.
---@param opts? table Scan options, including project context for source records.
---@return table result Scan result with `path` and collected bibliography index data.
function M.scan(path, opts)
    opts = opts or {}
    local out = empty_collected(opts.project)
    local seen = { citations = {} }
    local ext = vim.fn.fnamemodify(path, ":e"):lower()

    if ext == "bib" then
        scan_bibtex(path, out, seen)
    elseif ext == "yml" or ext == "yaml" then
        scan_hayagriva(path, out, seen)
    end

    return {
        path = path,
        data = out,
    }
end

return M
