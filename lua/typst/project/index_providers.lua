local aggregate = require("typst.project.aggregate")
local log = require("typst.core.log")
local provider_adapter = require("typst.integrations.provider_adapter")
local providers = require("typst.integrations.providers")
local util = require("typst.core.util")

local M = {}

local provider_item_categories = {
    heading = "headings",
    label = "labels",
    reference = "references",
    citation = "citations",
    import = "imports",
    imported_binding = "imported_bindings",
    wildcard_import = "wildcard_imports",
    module_alias = "module_aliases",
    definition = "definitions",
    glossary = "glossary_entries",
    glossary_entry = "glossary_entries",
    todo = "todos",
    figure = "figures",
    table = "tables",
    equation = "equations",
    path = "paths",
}

local function provider_items(provider, project, opts)
    local provider_project = providers.project_context(project)
    return provider_adapter.invoke(
        provider,
        "collect",
        provider_project,
        opts,
        {
            kind = "index",
            async = false,
            accept_table_result = true,
            args = { provider_project, opts },
            callback_position = 3,
        }
    )
end

local function normalize_provider_source(project, source)
    source = type(source) == "table" and vim.deepcopy(source) or {}
    source.path = util.resolve_path(source.path or project.main, project.root)
        or project.main
    source.lnum = tonumber(source.lnum or source.line) or 1
    source.col = tonumber(source.col or source.column) or 1
    return source
end

local function normalize_provider_item(project, item, provider_name)
    if type(item) ~= "table" then
        return nil, nil
    end

    local kind = item.kind or item.type
    local category = provider_item_categories[kind] or item.category
    if type(category) ~= "string" or category == "" then
        return nil, nil
    end

    local normalized = vim.deepcopy(item)
    normalized.kind = kind or normalized.kind
    normalized.name = normalized.name
        or normalized.title
        or normalized.text
        or normalized.word
        or normalized.spec
    normalized.source =
        normalize_provider_source(project, normalized.source or {
            path = normalized.path or normalized.file,
            lnum = normalized.lnum or normalized.line,
            col = normalized.col or normalized.column,
        })
    normalized.provider = normalized.provider or provider_name
    return category, normalized
end

local function merge_normalized_items(out, seen, project, result, provider_name)
    local collected = aggregate.empty_collected(project)
    for _, item in ipairs(result.items or {}) do
        local category, normalized =
            normalize_provider_item(project, item, provider_name)
        if category and collected[category] then
            collected[category][#collected[category] + 1] = normalized
        end
    end
    aggregate.merge(out, seen, collected)
end

function M.collect(project, opts)
    local out = aggregate.empty_collected(project)
    local seen = aggregate.empty_seen()

    for _, name in ipairs(providers.names("index")) do
        local result =
            provider_items(providers.get("index", name), project, opts)
        if type(result) == "table" and result.ok ~= false then
            aggregate.merge(out, seen, result)
            merge_normalized_items(out, seen, project, result, name)
        elseif type(result) == "table" then
            log.add("warn", "index provider failed", {
                provider = name,
                reason = result.reason,
                message = result.message,
            })
        end
    end

    return out
end

return M
