local aggregate = require("typst.project.aggregate")
local heading_scanner = require("typst.project.headings")
local index_cache = require("typst.project.index_cache")
local index_providers = require("typst.project.index_providers")
local index_scheduler = require("typst.project.index_scheduler")
local index_traversal = require("typst.project.index_traversal")
local import_enrichment = require("typst.project.imports")
local project_context = require("typst.project.context")
local semantic = require("typst.project.semantic")

local M = {}

function M.normalize_project_opts(project_or_opts)
    if type(project_or_opts) == "table" and project_or_opts.root then
        return { project = project_or_opts }
    end
    return project_or_opts or {}
end

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

local function collect_fresh(project, project_index, opts, traversal)
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
    return out
end

function M.collect(project_or_opts)
    local opts = M.normalize_project_opts(project_or_opts)
    local project = project_context.resolve(opts)
    if not project then
        return nil
    end

    local refresh = index_scheduler.prepare(project, opts)
    local project_index = refresh.project_index
    local aggregate_cache_enabled = refresh.aggregate_cache_enabled
    local buffer_map = refresh.buffer_map

    if opts.include_tinymist == true then
        local syntactic_opts = vim.tbl_extend("force", opts, {
            include_tinymist = false,
            mutable = true,
            _buffer_map = buffer_map,
        })
        local syntactic = M.collect(syntactic_opts)
        if not syntactic then
            return nil
        end
        -- Semantic workspace merging expects the same traversal context as the
        -- normal collection path. The syntactic aggregate can be reused above,
        -- but the traversal itself is cheap after file records are cached and
        -- preserves the semantic-provider contract.
        local traversal = index_traversal.collect(project)
        project_index.traversal = vim.deepcopy(traversal.summary or {})
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
    project_index.traversal = vim.deepcopy(traversal.summary or {})
    local signature =
        index_scheduler.traversal_signature(project, project_index, traversal)
    local watched_paths = index_scheduler.watch_paths(traversal)

    if
        aggregate_cache_enabled
        and project_index.aggregate
        and project_index.aggregate.signature == signature
    then
        -- Traversal still ran so stale project files can be pruned and watchers
        -- updated, but the expensive item merge can reuse the prior snapshot.
        index_cache.record_hit(project_index, "collect_hits")
        index_scheduler.commit_reused_aggregate(
            project,
            project_index,
            traversal,
            watched_paths,
            buffer_map
        )
        return aggregate.cached(project, project_index.aggregate.data, opts)
    end

    local out = collect_fresh(project, project_index, opts, traversal)
    if aggregate_cache_enabled then
        index_scheduler.commit_new_aggregate(
            project,
            project_index,
            traversal,
            signature,
            watched_paths,
            buffer_map,
            aggregate.snapshot(out)
        )
    end

    return out
end

function M.category(project_or_opts, name, collect_fn)
    local opts = M.normalize_project_opts(project_or_opts)
    local project = project_context.resolve(opts)
    if not project then
        return {}
    end

    local project_index = index_cache.ensure(project)
    local aggregate_cache_enabled =
        index_scheduler.aggregate_cache_enabled(opts)
    local refresh = nil
    if aggregate_cache_enabled then
        refresh = index_scheduler.prepare(project, opts)
        project_index = refresh.project_index
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

    local collect = collect_fn or M.collect
    local collected = collect(vim.tbl_extend("force", opts, {
        _buffer_map = refresh and refresh.buffer_map or opts._buffer_map,
    }))
    return collected and collected[name] or {}
end

return M
