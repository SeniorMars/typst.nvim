local aggregate = require("typst.project.index.aggregate")
local heading_scanner = require("typst.project.headings")
local index_cache = require("typst.project.index.cache")
local index_files = require("typst.project.index.files")
local index_providers = require("typst.project.index.providers")
local index_traversal = require("typst.project.index.traversal")
local import_enrichment = require("typst.project.imports")
local project_context = require("typst.project.context")
local project_registry = require("typst.project")
local providers = require("typst.integrations.providers")
local semantic = require("typst.project.semantic")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}
local project_buffer_path = index_files.project_buffer_path

local function seen_from_collected(project, collected)
    local seen = aggregate.empty_seen()
    local scratch = aggregate.empty_collected(project)
    aggregate.merge(scratch, seen, collected or {})
    return seen
end

local function merge_semantic_overlay(project, out, opts, traversal)
    local seen = seen_from_collected(project, out)
    local helpers = heading_scanner.semantic_helpers()
    semantic.merge_document_symbols(project, out, seen, opts, helpers)
    semantic.merge_workspace_symbols(
        project,
        out,
        seen,
        opts,
        traversal,
        helpers
    )
    import_enrichment.enrich(out, seen)
    aggregate.classify_references(out)
    aggregate.sort(out, project)
    return out
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

-- Project index aggregation.
--
-- Navigation, completion, package highlighting, bibliography, and TOC all read
-- from this cache. Invalidation combines buffer ticks, disk signatures,
-- dependency graph changes, and provider generations so most calls can reuse a
-- project snapshot instead of rescanning every Typst file.
local function sync_provider_generation(project_index)
    local generation = providers.generation("index")
    if project_index.provider_generation ~= generation then
        project_index.provider_generation = generation
        index_cache.bump(project_index, "index provider changed")
    end
end

local function sync_collect_generations(project, project_index)
    local buffer_map = util.loaded_buffers_by_path()
    index_cache.sync_config_generation(project_index)
    sync_provider_generation(project_index)
    index_cache.sync_dependency_generation(project, project_index)
    index_cache.sync_buffer_generation(
        project,
        project_index,
        project_index.aggregate and project_index.aggregate.watched_paths,
        project_buffer_path,
        buffer_map
    )
    index_cache.sync_file_generation(
        project_index,
        project_index.aggregate and project_index.aggregate.watched_paths,
        buffer_map
    )
end

local function collect_impl(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    if not project then
        return nil
    end

    local project_index = index_cache.ensure(project)
    local aggregate_cache_enabled = opts.include_tinymist ~= true
    sync_collect_generations(project, project_index)

    if opts.include_tinymist == true then
        local syntactic_opts = vim.tbl_extend("force", opts, {
            include_tinymist = false,
            mutable = true,
        })
        local syntactic = collect_impl(syntactic_opts)
        if not syntactic then
            return nil
        end
        -- Semantic workspace merging expects the same traversal context as the
        -- normal collection path. The syntactic aggregate can be reused above,
        -- but the traversal itself is cheap after file records are cached and
        -- preserves the semantic-provider contract.
        local traversal = index_traversal.collect(project)
        return merge_semantic_overlay(project, syntactic, opts, traversal)
    end

    -- Tinymist-backed semantic merges can be request-specific, so callers that
    -- include Tinymist reuse the syntactic aggregate and layer currently valid
    -- semantic results onto a mutable copy above.
    if
        aggregate_cache_enabled
        and project_index.aggregate
        and project_index.aggregate.generation == project_index.generation
    then
        index_cache.record_hit(project_index, "collect_hits")
        index_cache.record_hits(
            project_index,
            "file_hits",
            project_index.aggregate.file_count
        )
        index_cache.record_hits(
            project_index,
            "bibliography_hits",
            project_index.aggregate.bibliography_count
        )
        return aggregate.cached(project, project_index.aggregate.data, opts)
    end

    local traversal = index_traversal.collect(project)
    local signature = index_traversal.signature(project, traversal)
        .. "\nindex_providers\n"
        .. tostring(project_index.provider_generation or 0)
    local watched_paths = index_traversal.watch_paths(traversal)

    if
        aggregate_cache_enabled
        and project_index.aggregate
        and project_index.aggregate.signature == signature
    then
        -- Traversal still ran so stale project files can be pruned and watchers
        -- updated, but the expensive item merge can reuse the prior snapshot.
        index_cache.record_hit(project_index, "collect_hits")
        index_traversal.prune(
            project,
            traversal.visited,
            traversal.bibliography_paths
        )
        project_index.aggregate.generation = project_index.generation
        project_index.aggregate.file_count = #(traversal.records or {})
        project_index.aggregate.bibliography_count =
            vim.tbl_count(traversal.bibliography_records or {})
        project_index.aggregate.watched_paths = watched_paths
        index_cache.sync_file_watchers(project_index, watched_paths)
        local buffer_map = util.loaded_buffers_by_path()
        project_index.buffer_ticks = index_cache.current_buffer_ticks(
            project,
            watched_paths,
            project_buffer_path,
            buffer_map
        )
        project_index.file_signatures =
            index_cache.current_file_signatures(watched_paths, buffer_map)
        project_index.file_signatures_initialized = true
        return aggregate.cached(project, project_index.aggregate.data, opts)
    end

    index_cache.record_hit(project_index, "collect_misses")
    local out = aggregate.empty_collected(project)
    local seen = aggregate.empty_seen()

    for _, record in ipairs(traversal.records) do
        aggregate.merge(out, seen, record.data)
    end

    index_traversal.add_project_files(project, out, seen)
    index_traversal.merge_bibliography_records(
        out,
        seen,
        traversal.bibliography_records
    )
    aggregate.merge(out, seen, index_providers.collect(project, opts))
    local helpers = heading_scanner.semantic_helpers()
    semantic.merge_document_symbols(project, out, seen, opts, helpers)
    semantic.merge_workspace_symbols(
        project,
        out,
        seen,
        opts,
        traversal,
        helpers
    )
    import_enrichment.enrich(out, seen)
    aggregate.classify_references(out)
    index_traversal.prune(project, traversal.visited, out.bibliography_paths)
    aggregate.sort(out, project)

    if aggregate_cache_enabled then
        project_index.aggregate = {
            generation = project_index.generation,
            signature = signature,
            data = aggregate.snapshot(out),
            file_count = #(traversal.records or {}),
            bibliography_count = vim.tbl_count(
                traversal.bibliography_records or {}
            ),
            watched_paths = watched_paths,
        }
        index_cache.sync_file_watchers(project_index, watched_paths)
        local buffer_map = util.loaded_buffers_by_path()
        project_index.buffer_ticks = index_cache.current_buffer_ticks(
            project,
            watched_paths,
            project_buffer_path,
            buffer_map
        )
        project_index.file_signatures =
            index_cache.current_file_signatures(watched_paths, buffer_map)
        project_index.file_signatures_initialized = true
    end

    return out
end

--- Collect the project index used by navigation, completion, bibliography, and TOC.
--- With `include_tinymist = true`, returns syntactic data plus currently valid
--- semantic cache entries while scheduling stale or missing Tinymist data
--- asynchronously.
---@param opts? table Collection options, including `bufnr`, `project`, and `include_tinymist`.
---@return TypstCollectedIndex|nil index Collected index snapshot, or nil when no project resolves.
function M.collect(opts)
    local collected = telemetry.time("index.collect", function()
        return collect_impl(opts)
    end)
    return collected
end

local function category(project_or_opts, name)
    local opts = type(project_or_opts) == "table"
            and project_or_opts.root
            and { project = project_or_opts }
        or project_or_opts
        or {}
    local project = project_context.resolve(opts)
    if not project then
        return {}
    end

    local project_index = index_cache.ensure(project)
    local aggregate_cache_enabled = opts.include_tinymist ~= true
    if aggregate_cache_enabled then
        sync_collect_generations(project, project_index)
        if
            project_index.aggregate
            and project_index.aggregate.generation
                == project_index.generation
        then
            index_cache.record_hit(project_index, "collect_hits")
            return aggregate.cached_category(
                project_index.aggregate.data,
                name,
                opts
            )
        end
    end

    local collected = M.collect(opts)
    return collected and collected[name] or {}
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
    local project = type(project_or_opts) == "table"
            and project_or_opts.root
            and project_or_opts
        or project_context.resolve(project_or_opts or {})
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
        index_cache.reset(project_or_opts)
        return
    end

    for _, project in pairs(project_registry.all()) do
        index_cache.reset(project)
    end
end

return M
