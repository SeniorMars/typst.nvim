local completion_items = require("typst.completion.items")
local config = require("typst.config")
local index = require("typst.index")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

local M = {}

local item_info = completion_items.info

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function bibliography_completion_mode(opts)
    local mode = opts and opts.bibliography_completion
    if mode == nil and opts and opts.citation_completion ~= nil then
        mode = opts.citation_completion
    end
    if mode == nil then
        local bibliography = config.unsafe_get().bibliography or {}
        mode = bibliography.completion
    end

    if mode == false or mode == "off" then
        return "off"
    end
    if mode == "tinymist" then
        return "tinymist"
    end
    if mode == "project" then
        return "project"
    end
    return "auto"
end

local function include_project_citations(opts)
    local mode = bibliography_completion_mode(opts)
    if mode == "project" then
        return true
    end
    if mode ~= "auto" then
        return false
    end

    if opts and opts.include_tinymist == false then
        return true
    end

    if tinymist.coc_active() then
        return false
    end

    local bufnr = normalize_bufnr(opts and opts.bufnr)
    return not tinymist.available(bufnr)
end

local function menu(kind)
    return ({
        label = "[Typst label]",
        reference = "[Typst reference]",
        citation = "[Typst citation]",
        path = "[Typst path]",
        ["function"] = "[Typst project function]",
        glossary = "[Typst glossary]",
        ["local"] = "[Typst local]",
        import = "[Typst import]",
        member = "[Typst import member]",
        package = "[Typst package]",
    })[kind] or "[Typst project]"
end

local function item_kind(kind)
    return ({
        label = "r",
        reference = "r",
        citation = "r",
        path = "f",
        ["function"] = "f",
        glossary = "v",
        ["local"] = "v",
        import = "v",
        member = "m",
        package = "m",
    })[kind] or "v"
end

local function location_label(source)
    if type(source) ~= "table" or not source.path then
        return nil
    end

    local label = source.path
    if source.lnum then
        label = ("%s:%d"):format(label, source.lnum)
    end
    return label
end

local function project_item(word, kind, item)
    return {
        word = word,
        abbr = word,
        menu = menu(kind),
        kind = item_kind(kind),
        info = item_info({
            item.imported_name and ("Imported from: " .. item.imported_name)
                or nil,
            item.spec and ("Source: " .. item.spec) or nil,
            item.path and ("Path: " .. item.path) or nil,
            location_label(item.definition or item.source),
        }),
        user_data = {
            typst = {
                kind = kind,
                provider = "project",
                semantic = false,
            },
        },
    }
end

local function completion_buffer_path(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    return path ~= "" and util.normalize(path) or nil
end

local function definition_visible(item, collected, bufnr)
    local source = item.source or {}
    if not source.path then
        return true
    end

    local current_path = completion_buffer_path(bufnr)
    return util.same_path(source.path, current_path)
        or (
            collected.project
            and util.same_path(source.path, collected.project.main)
        )
end

local function import_visible(item, collected, bufnr)
    local source = item.source or {}
    if not source.path then
        return true
    end

    local current_path = completion_buffer_path(bufnr)
    return util.same_path(source.path, current_path)
        or (
            collected.project
            and util.same_path(source.path, collected.project.main)
        )
end

function M.items(opts, base)
    if opts.include_project == false then
        return {}
    end

    local collected = index.collect({
        bufnr = opts.bufnr,
        project = opts.project,
    })
    if not collected then
        return {}
    end

    local items = {}
    local seen = {}
    local function add(word, kind, item)
        completion_items.add_unique(items, seen, word, function(value)
            return project_item(value, kind, item)
        end, { base = base, trim = false })
    end

    for _, item in ipairs(collected.definitions) do
        if definition_visible(item, collected, opts.bufnr) then
            add(item.name, item.kind, item)
        end
    end
    for _, item in ipairs(collected.imported_bindings) do
        if import_visible(item, collected, opts.bufnr) then
            add(item.name, item.kind, item)
        end
    end
    for _, item in ipairs(collected.imports) do
        if item.kind == "package" then
            add(item.spec, "package", item)
        end
    end
    for _, item in ipairs(collected.labels) do
        add(item.name, "label", item)
    end
    for _, item in ipairs(collected.references) do
        if item.reference_target ~= "citation" then
            add(item.name, "reference", item)
        end
    end
    if include_project_citations(opts) then
        for _, item in ipairs(collected.citations) do
            add(item.name, "citation", item)
        end
    end
    for _, item in ipairs(collected.glossary_entries or {}) do
        add(item.name, "glossary", item)
    end
    for _, item in ipairs(collected.paths) do
        add(item.word, "path", item)
    end

    table.sort(items, function(a, b)
        if a.word == b.word then
            return a.menu < b.menu
        end
        return a.word < b.word
    end)

    return items
end

local function current_buffer_path(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    return path ~= "" and util.normalize(path) or nil
end

local function definition_before_position(item, current_path, row)
    local source = item.definition or item.source
    if
        type(source) ~= "table"
        or not source.path
        or not current_path
        or not util.same_path(source.path, current_path)
    then
        return true
    end

    if not source.lnum or row == nil then
        return true
    end

    return source.lnum < row + 1
end

function M.function_result(bufnr, name, row)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local collected = index.collect({ bufnr = bufnr })
    if not collected then
        return nil
    end

    local current_path = current_buffer_path(bufnr)
    local best = nil
    local function consider(item)
        if
            item.name == name
            and item.kind == "function"
            and type(item.parameters) == "table"
            and #item.parameters > 0
            and definition_before_position(item, current_path, row)
        then
            local source = item.definition or item.source or {}
            local source_is_current = util.same_path(source.path, current_path)
            local best_is_current = best
                and util.same_path(best.source.path, current_path)
            if
                not best
                or (source_is_current and not best_is_current)
                or (
                    util.same_path(source.path, best.source.path)
                    and (source.lnum or 0) > (best.source.lnum or 0)
                )
            then
                best = {
                    item = item,
                    source = source,
                }
            end
        end
    end

    for _, item in ipairs(collected.definitions or {}) do
        consider(item)
    end
    for _, item in ipairs(collected.imported_bindings or {}) do
        if import_visible(item, collected, bufnr) then
            consider(item)
        end
    end

    if not best then
        return nil
    end

    return {
        id = "project." .. name,
        kind = "function",
        name = name,
        qualified_name = best.item.name,
        title = best.item.name,
        signature = best.item.signature or (best.item.name .. "(...)"),
        parameters = vim.deepcopy(best.item.parameters),
        source = best.source,
        provider = "project",
        provider_name = "Typst project index",
        semantic = false,
    }
end

return M
