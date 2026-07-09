local index_cache = require("typst.project.index_cache")
local index_files = require("typst.project.index_files")
local index_traversal = require("typst.project.index_traversal")
local providers = require("typst.integrations.providers")
local util = require("typst.core.util")

local M = {}

M.project_buffer_path = index_files.project_buffer_path

function M.aggregate_cache_enabled(opts)
    return not (opts and opts.include_tinymist == true)
end

function M.sync_provider_generation(project_index)
    local generation = providers.generation("index")
    if project_index.provider_generation ~= generation then
        project_index.provider_generation = generation
        index_cache.bump(project_index, "index provider changed")
    end
end

function M.sync_collect_generations(project, project_index, buffer_map)
    buffer_map = buffer_map or util.loaded_buffers_by_path()
    index_cache.sync_config_generation(project_index)
    M.sync_provider_generation(project_index)
    index_cache.sync_dependency_generation(project, project_index)
    index_cache.sync_buffer_generation(
        project,
        project_index,
        project_index.aggregate and project_index.aggregate.watched_paths,
        M.project_buffer_path,
        buffer_map
    )
    index_cache.sync_file_generation(
        project_index,
        project_index.aggregate and project_index.aggregate.watched_paths,
        buffer_map
    )
end

function M.prepare(project, opts)
    opts = opts or {}
    local project_index = index_cache.ensure(project)
    local buffer_map = opts._buffer_map or util.loaded_buffers_by_path()
    M.sync_collect_generations(project, project_index, buffer_map)
    return {
        project = project,
        project_index = project_index,
        buffer_map = buffer_map,
        aggregate_cache_enabled = M.aggregate_cache_enabled(opts),
    }
end

function M.traversal_signature(project, project_index, traversal)
    return index_traversal.signature(project, traversal)
        .. "\nindex_providers\n"
        .. tostring(project_index.provider_generation or 0)
end

function M.watch_paths(traversal)
    return index_traversal.watch_paths(traversal)
end

function M.commit_reused_aggregate(
    project,
    project_index,
    traversal,
    watched_paths,
    buffer_map
)
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
    project_index.aggregate.traversal = vim.deepcopy(traversal.summary or {})
    M.commit_freshness(project, project_index, watched_paths, buffer_map)
end

function M.commit_new_aggregate(
    project,
    project_index,
    traversal,
    signature,
    watched_paths,
    buffer_map,
    snapshot
)
    project_index.aggregate = {
        generation = project_index.generation,
        signature = signature,
        data = snapshot,
        file_count = #(traversal.records or {}),
        bibliography_count = vim.tbl_count(
            traversal.bibliography_records or {}
        ),
        watched_paths = watched_paths,
        traversal = vim.deepcopy(traversal.summary or {}),
    }
    M.commit_freshness(project, project_index, watched_paths, buffer_map)
end

function M.commit_freshness(project, project_index, watched_paths, buffer_map)
    index_cache.sync_file_watchers(project_index, watched_paths)
    project_index.buffer_ticks = index_cache.current_buffer_ticks(
        project,
        watched_paths,
        M.project_buffer_path,
        buffer_map
    )
    project_index.file_signatures =
        index_cache.current_file_signatures(watched_paths, buffer_map)
    project_index.file_signatures_initialized = true
end

return M
