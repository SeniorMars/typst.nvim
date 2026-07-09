local index_cache = require("typst.project.index_cache")
local index_service = require("typst.project.index_service")
local project_context = require("typst.project.context")
local project_store = require("typst.project.store")
local telemetry = require("typst.core.telemetry")

local M = {}

local function timed_collect(opts)
    local collected = telemetry.time("index.collect", function()
        return index_service.collect(opts)
    end)
    return collected
end

---@class TypstCollectedIndex
---@field headings table[]
---@field labels table[]
---@field references table[]
---@field citations table[]
---@field imports table[]
---@field imported_bindings table[]
---@field wildcard_imports table[]
---@field module_aliases table[]
---@field definitions table[]
---@field glossary_entries table[]
---@field todos table[]
---@field figures table[]
---@field tables table[]
---@field equations table[]
---@field paths table[]

--- Collect the project index used by navigation, completion, bibliography, and TOC.
--- With `include_tinymist = true`, returns syntactic data plus currently valid
--- semantic cache entries while scheduling stale or missing Tinymist data
--- asynchronously.
---@param opts? table Collection options, including `bufnr`, `project`, and `include_tinymist`.
---@return TypstCollectedIndex|nil index Collected index snapshot, or nil when no project resolves.
function M.collect(opts)
    return timed_collect(opts)
end

local function category(project_or_opts, name)
    return index_service.category(project_or_opts, name, timed_collect)
end

--- Return indexed headings for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] headings Heading records in project order.
function M.headings(project_or_opts)
    return category(project_or_opts, "headings")
end

--- Return indexed labels for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] labels Label records in project order.
function M.labels(project_or_opts)
    return category(project_or_opts, "labels")
end

--- Return indexed citation references for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] citations Citation records in project order.
function M.citations(project_or_opts)
    return category(project_or_opts, "citations")
end

--- Return indexed imports for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] imports Import records in project order.
function M.imports(project_or_opts)
    return category(project_or_opts, "imports")
end

--- Return indexed TODO-like comments for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] todos TODO records in project order.
function M.todos(project_or_opts)
    return category(project_or_opts, "todos")
end

--- Return indexed definitions for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] definitions Definition records in project order.
function M.definitions(project_or_opts)
    return category(project_or_opts, "definitions")
end

--- Return indexed glossary entries for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] entries Glossary entry records in project order.
function M.glossary_entries(project_or_opts)
    return category(project_or_opts, "glossary_entries")
end

--- Return indexed path references for a project or buffer options.
---@param project_or_opts? table Project state or collection options.
---@return table[] paths Path reference records in project order.
function M.paths(project_or_opts)
    return category(project_or_opts, "paths")
end

--- Mark a project index dirty so the next collection refreshes cached data.
---@param project_or_opts? table Project state or collection options.
---@param reason? string Invalidation reason stored in cache/debug state.
---@return boolean ok True when a project was found and marked dirty.
function M.mark_dirty(project_or_opts, reason)
    local project = project_context.resolve(
        index_service.normalize_project_opts(project_or_opts)
    )
    if not project then
        return false
    end

    index_cache.bump(index_cache.ensure(project), reason or "manual")
    return true
end

--- Clear index cache state for one project or all projects.
---@param project_or_opts? table Project state, options table, or nil for all projects.
function M.reset(project_or_opts)
    if type(project_or_opts) == "table" and project_or_opts.root then
        local project = project_context.resolve({ project = project_or_opts })
        if project then
            index_cache.reset(project)
        end
        return
    end

    for _, project in pairs(project_store.all()) do
        index_cache.reset(project)
    end
end

return M
