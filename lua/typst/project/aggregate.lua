local util = require("typst.core.util")

local M = {}

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

--- Create an empty project index aggregate.
---@param project table Project state attached to the aggregate.
---@return table collected Empty aggregate table.
function M.empty_collected(project)
    return {
        project = project,
        headings = {},
        labels = {},
        references = {},
        citations = {},
        imports = {},
        imported_bindings = {},
        wildcard_imports = {},
        module_aliases = {},
        definitions = {},
        definitions_by_file = {},
        glossary_entries = {},
        todos = {},
        figures = {},
        tables = {},
        equations = {},
        paths = {},
        bibliography_paths = {},
    }
end

--- Create per-category de-duplication state for aggregation.
---@return table seen Empty seen-key tables.
function M.empty_seen()
    return {
        headings = {},
        labels = {},
        references = {},
        citations = {},
        imports = {},
        imported_bindings = {},
        wildcard_imports = {},
        module_aliases = {},
        definitions = {},
        glossary_entries = {},
        todos = {},
        figures = {},
        tables = {},
        equations = {},
        paths = {},
    }
end

local function list_key(item)
    local source = item.source or {}
    return ("%s\n%s\n%s\n%s"):format(
        item.name or item.word or item.spec or item.kind or "",
        source.path or "",
        source.lnum or "",
        source.col or ""
    )
end

local merge_keys = {
    headings = list_key,
    labels = function(item)
        return item.name
    end,
    references = list_key,
    citations = function(item)
        return item.name
    end,
    imports = function(item)
        return (item.spec or "") .. "\n" .. ((item.source or {}).path or "")
    end,
    imported_bindings = function(item)
        return ("%s\n%s\n%s\n%s"):format(
            item.name or "",
            (item.source or {}).path or "",
            item.path or "",
            item.spec or ""
        )
    end,
    wildcard_imports = function(item)
        return ("%s\n%s\n%s"):format(
            (item.source or {}).path or "",
            item.path or "",
            item.spec or ""
        )
    end,
    module_aliases = function(item)
        return item.name
    end,
    definitions = function(item)
        return ((item.source or {}).path or "") .. "\n" .. (item.name or "")
    end,
    glossary_entries = function(item)
        return item.name
    end,
    todos = list_key,
    figures = list_key,
    tables = list_key,
    equations = list_key,
    paths = function(item)
        return item.word or item.path
    end,
}

local function merge_list(out, seen, category, values)
    local key_fn = merge_keys[category] or list_key
    for _, item in ipairs(values or {}) do
        add_unique(
            out[category],
            seen[category],
            key_fn(item),
            vim.deepcopy(item)
        )
    end
end

--- Merge one collected index result into an aggregate.
---@param out table Aggregate output table to mutate.
---@param seen table Per-category seen-key tables.
---@param collected table Collected index result to merge.
function M.merge(out, seen, collected)
    for category in pairs(merge_keys) do
        merge_list(out, seen, category, collected[category])
    end

    for path, spec in pairs(collected.bibliography_paths or {}) do
        out.bibliography_paths[path] = spec
    end

    for path, definitions in pairs(collected.definitions_by_file or {}) do
        out.definitions_by_file[path] = out.definitions_by_file[path] or {}
        for name, item in pairs(definitions) do
            out.definitions_by_file[path][name] = vim.deepcopy(item)
        end
    end
end

local aggregate_list_categories = {
    "headings",
    "labels",
    "references",
    "citations",
    "imports",
    "imported_bindings",
    "wildcard_imports",
    "module_aliases",
    "definitions",
    "glossary_entries",
    "todos",
    "figures",
    "tables",
    "equations",
    "paths",
}

local function copy_list(values)
    local copy = {}
    for index, item in ipairs(values or {}) do
        copy[index] = vim.deepcopy(item)
    end
    return copy
end

--- Copy an aggregate into cacheable snapshot form.
---@param out table Aggregate output table.
---@return table snapshot Cache snapshot.
function M.snapshot(out)
    local snapshot = {}
    snapshot.project = out and out.project or nil
    for _, category in ipairs(aggregate_list_categories) do
        snapshot[category] = copy_list(out[category])
    end
    snapshot.definitions_by_file = vim.deepcopy(out.definitions_by_file or {})
    snapshot.bibliography_paths = vim.deepcopy(out.bibliography_paths or {})
    return snapshot
end

--- Restore a mutable aggregate from a cached snapshot.
---@param project table Project state attached to the restored aggregate.
---@param snapshot table Cached aggregate snapshot.
---@return table collected Mutable aggregate table.
function M.restore(project, snapshot)
    local out = M.empty_collected(project)
    for _, category in ipairs(aggregate_list_categories) do
        out[category] = copy_list(snapshot and snapshot[category])
    end
    out.definitions_by_file =
        vim.deepcopy((snapshot and snapshot.definitions_by_file) or {})
    out.bibliography_paths =
        vim.deepcopy((snapshot and snapshot.bibliography_paths) or {})
    return out
end

local function wants_mutable(opts)
    return opts and (opts.mutable == true or opts.copy == true)
end

local function wants_shared(opts)
    return not wants_mutable(opts) and (not opts or opts.shared ~= false)
end

--- Return a cached aggregate as shared or mutable data.
---@param project table Project state attached to the returned aggregate.
---@param snapshot? table Cached aggregate snapshot.
---@param opts? table Cache options; `mutable`/`copy` requests a deep copy.
---@return table collected Aggregate result.
function M.cached(project, snapshot, opts)
    if not snapshot then
        return M.empty_collected(project)
    end

    if wants_mutable(opts) then
        return M.restore(project, snapshot)
    end

    snapshot.project = project
    return snapshot
end

--- Restore one aggregate category from a cached snapshot.
---@param snapshot table Cached aggregate snapshot.
---@param category string Aggregate category name.
---@return table values Mutable category value.
function M.restore_category(snapshot, category)
    if
        category == "definitions_by_file"
        or category == "bibliography_paths"
    then
        return vim.deepcopy((snapshot and snapshot[category]) or {})
    end
    return copy_list(snapshot and snapshot[category])
end

--- Return one cached aggregate category as shared or mutable data.
---@param snapshot table Cached aggregate snapshot.
---@param category string Aggregate category name.
---@param opts? table Cache options; `mutable`/`copy` requests a deep copy.
---@return table values Category values.
function M.cached_category(snapshot, category, opts)
    if wants_mutable(opts) or (opts and opts.shared == false) then
        return M.restore_category(snapshot, category)
    end

    return (snapshot and snapshot[category]) or {}
end

--- Classify collected references as label, citation, or unknown targets.
---@param out table Aggregate output table mutated in place.
function M.classify_references(out)
    local labels = {}
    local citations = {}

    for _, item in ipairs(out.labels or {}) do
        if item.name then
            labels[item.name] = true
        end
    end
    for _, item in ipairs(out.citations or {}) do
        if item.name then
            citations[item.name] = true
        end
    end

    local function target_name(name, lookup)
        if lookup[name] then
            return name
        end

        local trimmed = type(name) == "string" and name:gsub("[%.,;:]+$", "")
            or nil
        if trimmed and trimmed ~= name and lookup[trimmed] then
            return trimmed
        end
    end

    for _, item in ipairs(out.references or {}) do
        if not (item.semantic and item.reference_target) then
            local label_name = target_name(item.name, labels)
            local citation_name = target_name(item.name, citations)
            if item.reference_style == "cite" and citation_name then
                item.reference_target = "citation"
                item.reference_target_name = citation_name
            elseif item.reference_style == "function" or label_name then
                item.reference_target = "label"
                item.reference_target_name = label_name or item.name
            elseif citation_name then
                item.reference_target = "citation"
                item.reference_target_name = citation_name
            else
                item.reference_target = "unknown"
                item.reference_target_name = item.name
            end
        end
    end
end

--- Sort aggregate categories for deterministic UI and cache output.
---@param out table Aggregate output table mutated in place.
---@param project table Project state used to prioritize main-file headings.
function M.sort(out, project)
    table.sort(out.labels, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.headings, function(a, b)
        if util.same_path(a.source.path, b.source.path) then
            return a.source.lnum < b.source.lnum
        end
        if util.same_path(a.source.path, project.main) then
            return true
        end
        if util.same_path(b.source.path, project.main) then
            return false
        end
        return a.source.path < b.source.path
    end)
    table.sort(out.references, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.citations, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.definitions, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.glossary_entries, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.imported_bindings, function(a, b)
        return a.name < b.name
    end)
    table.sort(out.todos, function(a, b)
        if util.same_path(a.source.path, b.source.path) then
            return a.source.lnum < b.source.lnum
        end
        return a.source.path < b.source.path
    end)
    table.sort(out.paths, function(a, b)
        return a.word < b.word
    end)
end

return M
