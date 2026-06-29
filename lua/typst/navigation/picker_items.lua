local picker_kinds = require("typst.navigation.picker_kinds")
local index = require("typst.index")
local project_context = require("typst.project.context")
local toc = require("typst.navigation.toc")
local util = require("typst.core.util")

---@class TypstPickerItem
---@field kind string
---@field name string
---@field text string
---@field label string
---@field detail string
---@field filename string
---@field lnum number
---@field col number
---@field project table
---@field item table

local M = {}

local function source_from(path, lnum, col)
    return {
        path = path,
        lnum = lnum or 1,
        col = col or 1,
    }
end

local function format_detail(project, source)
    local path = source.path or project.main
    return ("%s:%d:%d"):format(
        util.relpath(path, project.root),
        source.lnum or 1,
        source.col or 1
    )
end

local function make_item(project, kind, name, source, raw, opts)
    opts = opts or {}
    source = source or source_from(project.main, 1, 1)
    source.path = source.path or project.main
    source.lnum = source.lnum or 1
    source.col = source.col or 1

    local detail = format_detail(project, source)
    local item = {
        kind = kind,
        name = name,
        text = name,
        label = ("[%s] %s  %s"):format(kind, name, detail),
        detail = detail,
        source = source,
        filename = source.path,
        lnum = source.lnum,
        col = source.col,
        project = project,
        item = raw,
    }

    if raw and raw.kind and raw.kind ~= kind then
        item.subkind = raw.kind
    end

    if opts.decorate then
        opts.decorate(item, raw)
    end

    return item
end

local function add_item(items, project, kinds, kind, name, source, raw, opts)
    if not kinds._all and not kinds[kind] then
        return
    end
    items[#items + 1] = make_item(project, kind, name, source, raw, opts)
end

local function toc_picker_name(item, layer, kind)
    local title = item.title or ""
    if kind == "toc" and layer ~= "heading" then
        return ("[%s] %s"):format(layer, title)
    end
    return title
end

local function add_toc_model_items(items, project, kinds, opts)
    local include_layers = opts.toc_layers
    if include_layers == nil then
        include_layers = picker_kinds.wants_toc_layers(kinds)
    end

    for _, item in
        ipairs(toc.collect(project, {
            backend = opts.toc_backend,
            layers = include_layers,
            timeout_ms = opts.timeout_ms,
        }))
    do
        local layer = item.layer or "heading"
        local known_kind = picker_kinds.is_toc_model(layer) and layer or nil
        local kind = nil

        if kinds.toc and not kinds._all then
            kind = "toc"
        elseif kinds[layer] then
            kind = layer
        elseif kinds._all then
            kind = known_kind or layer
        elseif known_kind and kinds[known_kind] then
            kind = known_kind
        elseif kinds.toc then
            kind = "toc"
        end

        if kind then
            add_item(
                items,
                project,
                kinds,
                kind,
                toc_picker_name(item, layer, kind),
                source_from(item.file, item.lnum, item.col),
                item,
                {
                    decorate = function(picker_item)
                        picker_item.level = item.level
                        picker_item.subkind = layer
                        picker_item.toc_layer = layer
                        picker_item.toc_source = item.source
                    end,
                }
            )
        end
    end
end

local function bibliography_insert_text(key, opts)
    local form = opts.citation_form
        or opts.bibliography_form
        or opts.insert_form
    local ok, bibliography = pcall(require, "typst.bibliography")
    if ok and type(bibliography.insert_text) == "function" then
        return bibliography.insert_text(
            key,
            vim.tbl_extend("force", opts, {
                form = form,
            })
        )
    end

    if form == "function" or form == "cite" then
        return ("#cite(<%s>)"):format(key)
    end
    if form == "label" or form == "raw" then
        return ("<%s>"):format(key)
    end
    return "@" .. key
end

local bibliography_search_fields = {
    "author",
    "editor",
    "title",
    "year",
    "date",
    "journal",
    "journaltitle",
    "booktitle",
    "keywords",
    "keyword",
    "abstract",
}

local function bibliography_fields(item)
    local fields = item.fields
    local source = item.source or {}
    local ok, bibliography = pcall(require, "typst.bibliography")
    if
        ok
        and type(bibliography.expanded_fields) == "function"
        and source.path
        and item.name
    then
        fields = vim.tbl_extend(
            "force",
            fields or {},
            bibliography.expanded_fields({
                path = source.path,
                key = item.name,
            })
        )
    end
    return fields
end

local function add_bibliography_items(items, project, kinds, opts)
    if not kinds.bibliography then
        return
    end

    local collected = index.collect({ project = project })
    for _, item in ipairs((collected or {}).citations or {}) do
        add_item(
            items,
            project,
            kinds,
            "bibliography",
            item.name,
            item.source,
            item,
            {
                decorate = function(picker_item)
                    picker_item.subkind = "citation"
                    picker_item.citation_key = item.name
                    picker_item.insert_text =
                        bibliography_insert_text(item.name, opts)
                    picker_item.fields = bibliography_fields(item)
                end,
            }
        )
    end
end

local function matches_query(item, query)
    if not query or query == "" then
        return true
    end

    query = query:lower()
    for _, field in ipairs({
        item.kind,
        item.name,
        item.label,
        item.detail,
        item.subkind,
        item.citation_key,
        item.insert_text,
    }) do
        if type(field) == "string" and field:lower():find(query, 1, true) then
            return true
        end
    end

    for _, name in ipairs(bibliography_search_fields) do
        local value = item.fields and item.fields[name]
        if value ~= nil and tostring(value):lower():find(query, 1, true) then
            return true
        end
    end

    return false
end

local function filter_items(items, query)
    if not query or query == "" then
        return items
    end

    return vim.tbl_filter(function(item)
        return matches_query(item, query)
    end, items)
end

local function sort_items(project, items)
    table.sort(items, function(a, b)
        local a_order = picker_kinds.order(a.kind)
        local b_order = picker_kinds.order(b.kind)
        if a_order ~= b_order then
            return a_order < b_order
        end
        if not util.same_path(a.filename, b.filename) then
            if util.same_path(a.filename, project.main) then
                return true
            end
            if util.same_path(b.filename, project.main) then
                return false
            end
            return a.filename < b.filename
        end
        if a.lnum ~= b.lnum then
            return a.lnum < b.lnum
        end
        if a.col ~= b.col then
            return a.col < b.col
        end
        return a.label < b.label
    end)
end

function M.kind_names()
    return picker_kinds.names()
end

function M.items(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    if not project then
        return {}
    end

    local kinds = picker_kinds.normalize(opts)
    local items = {}
    add_toc_model_items(items, project, kinds, opts)
    add_bibliography_items(items, project, kinds, opts)
    items = filter_items(items, opts.query)
    sort_items(project, items)
    return items
end

return M
