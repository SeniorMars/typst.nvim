local index = require("typst.index")
local log = require("typst.core.log")
local provider_adapter = require("typst.integrations.provider_adapter")
local providers = require("typst.integrations.providers")
local util = require("typst.core.util")

local M = {}

---@class TypstTocLayerItem
---@field file string
---@field lnum number
---@field col number
---@field level number
---@field title string
---@field layer? string
---@field source string

local function collect_treesitter(project, collected)
    local items = {}

    for _, item in ipairs((collected or {}).headings or {}) do
        local source = item.source or {}
        items[#items + 1] = {
            file = source.path or project.main,
            lnum = source.lnum or 1,
            col = source.col or 1,
            level = item.level or 1,
            title = item.title or item.name,
            source = item.source_kind or "index",
        }
    end

    table.sort(items, function(a, b)
        if util.same_path(a.file, b.file) then
            return a.lnum < b.lnum
        end
        if util.same_path(a.file, project.main) then
            return true
        end
        if util.same_path(b.file, project.main) then
            return false
        end
        return a.file < b.file
    end)

    return items
end

local layer_order = {
    heading = 1,
    figure = 2,
    table = 3,
    equation = 4,
    label = 5,
    reference = 6,
    citation = 7,
    import = 8,
    file = 9,
    todo = 10,
    definition = 11,
}

local function source_item(layer, title, source)
    if not source or not source.path then
        return nil
    end

    return {
        file = source.path,
        lnum = source.lnum or 1,
        col = source.col or 1,
        level = 1,
        title = title,
        layer = layer,
        source = "index",
    }
end

local function add_layer_item(items, layer, title, source)
    local item = source_item(layer, title, source)
    if item then
        items[#items + 1] = item
    end
end

local function collect_index_layers(project, collected)
    collected = collected or index.collect({ project = project })
    if not collected then
        return {}
    end

    local items = {}
    for _, item in ipairs(collected.figures or {}) do
        add_layer_item(items, "figure", "Figure", item.source)
    end
    for _, item in ipairs(collected.tables or {}) do
        add_layer_item(items, "table", "Table", item.source)
    end
    for _, item in ipairs(collected.equations or {}) do
        add_layer_item(items, "equation", "Equation", item.source)
    end
    for _, item in ipairs(collected.labels or {}) do
        add_layer_item(items, "label", item.name, item.source)
    end
    for _, item in ipairs(collected.references or {}) do
        if item.reference_target ~= "citation" then
            add_layer_item(items, "reference", "@" .. item.name, item.source)
        end
    end
    for _, item in ipairs(collected.citations or {}) do
        add_layer_item(items, "citation", item.name, item.source)
    end
    for _, item in ipairs(collected.imports or {}) do
        add_layer_item(
            items,
            item.kind == "package" and "import" or "file",
            item.spec,
            item.source
        )
    end
    for _, item in ipairs(collected.paths or {}) do
        if item.path_kind and item.path_kind ~= "project" then
            add_layer_item(
                items,
                "file",
                ("%s: %s"):format(item.path_kind, item.word),
                item.source
            )
        end
    end
    for _, item in ipairs(collected.todos or {}) do
        local title = item.text ~= "" and ("%s: %s"):format(item.tag, item.text)
            or item.tag
        add_layer_item(items, "todo", title, item.source)
    end
    for _, item in ipairs(collected.definitions or {}) do
        add_layer_item(items, "definition", item.name, item.source)
    end

    return items
end

local function normalize_provider_item(project, item, provider_name)
    if type(item) ~= "table" then
        return nil
    end

    local source = item.source or {}
    local file = item.file or item.path or source.path or project.main
    file = util.resolve_path(file, project.root)
    if not file then
        return nil
    end

    local title = item.title or item.name or item.text
    if type(title) ~= "string" or title == "" then
        return nil
    end

    return {
        file = file,
        lnum = tonumber(item.lnum or item.line or source.lnum) or 1,
        col = tonumber(item.col or item.column or source.col) or 1,
        level = tonumber(item.level) or 1,
        title = title,
        layer = item.layer or item.kind or provider_name,
        source = item.source_name or provider_name,
        data = item,
    }
end

local function provider_items(provider, project, opts)
    local provider_project = providers.project_context(project)
    return provider_adapter.invoke(
        provider,
        "collect",
        provider_project,
        opts,
        {
            kind = "toc",
            async = false,
            accept_table_result = true,
            args = { provider_project, opts },
            callback_position = 3,
        }
    )
end

local function collect_provider_layers(project, opts)
    if opts.providers == false then
        return {}
    end

    local items = {}
    for _, name in ipairs(providers.names("toc")) do
        local result = provider_items(providers.get("toc", name), project, opts)
        if type(result) == "table" and result.ok ~= false then
            local raw_items = type(result) == "table"
                    and (result.items or result)
                or {}
            for _, raw in ipairs(raw_items) do
                local item = normalize_provider_item(project, raw, name)
                if item then
                    items[#items + 1] = item
                end
            end
        elseif type(result) == "table" then
            log.add("warn", "toc provider failed", {
                provider = name,
                reason = result.reason,
                message = result.message,
            })
        end
    end
    return items
end

local function sort_items(project, items)
    table.sort(items, function(a, b)
        if util.same_path(a.file, b.file) then
            if a.lnum == b.lnum then
                local a_order = layer_order[a.layer or "heading"] or 99
                local b_order = layer_order[b.layer or "heading"] or 99
                if a_order == b_order then
                    return a.col < b.col
                end
                return a_order < b_order
            end
            return a.lnum < b.lnum
        end
        if util.same_path(a.file, project.main) then
            return true
        end
        if util.same_path(b.file, project.main) then
            return false
        end
        return a.file < b.file
    end)
end

function M.collect(project, opts)
    opts = opts or {}

    local collected = index.collect({ project = project })
    local items = collect_treesitter(project, collected)
    if opts.layers ~= false then
        vim.list_extend(items, collect_index_layers(project, collected))
        vim.list_extend(items, collect_provider_layers(project, opts))
        sort_items(project, items)
    end
    return items
end

return M
