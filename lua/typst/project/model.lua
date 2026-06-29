local config = require("typst.config")
local output_path_util = require("typst.compiler.output_path")
local invalidation = require("typst.project.invalidation")
local main_file = require("typst.project.main_file")
local graph_dependencies = require("typst.project.graph.dependencies")
local graph_sources = require("typst.project.graph.sources")
local services = require("typst.project.services")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local scratch_counter = 0
local scratch_session = ("%s-%s"):format(
    tostring(vim.fn.getpid()),
    string.format("%d", uv.hrtime())
)

--- Build the registry key for a Typst project.
---@param root string Project root path.
---@param main string Project main file path.
---@return string key Stable registry key.
function M.project_key(root, main)
    return util.path_key(root) .. "\n" .. util.path_key(main)
end

--- Return the precedence of a project association source.
---@param source? string Association source label.
---@return integer priority Higher values win.
function M.source_priority(source)
    return graph_sources.source_priority(source)
end

--- Choose the stronger project association source.
---@param current? string Existing source label.
---@param incoming? string Incoming source label.
---@return string? source Stronger source label.
function M.strongest_source(current, incoming)
    return graph_sources.strongest_source(current, incoming)
end

--- Compare two set-like tables by key membership.
---@param left? table First set-like table.
---@param right? table Second set-like table.
---@return boolean same True when both tables contain the same keys.
function M.same_key_set(left, right)
    return graph_sources.same_key_set(left, right)
end

--- Mark a project's index cache dirty and emit invalidation.
---@param project table Project state whose index generation is bumped.
---@param reason string Human-readable invalidation reason.
function M.mark_index_dirty(project, reason)
    local index = services.index(project)
    if type(index) ~= "table" then
        return
    end

    index.generation = (index.generation or 0) + 1
    index.dirty_reason = reason
    invalidation.emit_reason(project, reason, {
        index_generation = index.generation,
    })
end

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

--- Return the normalized file path for a buffer.
---@param bufnr integer Buffer to inspect.
---@return string? path Normalized buffer path, or nil for unnamed buffers.
function M.current_buffer_path(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        return nil
    end

    return util.normalize(path)
end

--- Return the synthetic cache path used for an unnamed Typst buffer.
---@param bufnr integer Buffer number.
---@return string path Cache path used to index unsaved source.
function M.scratch_buffer_path(bufnr)
    local path_ok, scratch_path =
        pcall(vim.api.nvim_buf_get_var, bufnr, "typst_scratch_path")
    if path_ok and type(scratch_path) == "string" and scratch_path ~= "" then
        return util.normalize(scratch_path)
    end

    local ok, scratch_id =
        pcall(vim.api.nvim_buf_get_var, bufnr, "typst_scratch_id")
    if not ok or type(scratch_id) ~= "number" then
        scratch_counter = scratch_counter + 1
        scratch_id = scratch_counter
        pcall(vim.api.nvim_buf_set_var, bufnr, "typst_scratch_id", scratch_id)
    end

    scratch_path = util.normalize(
        util.cache_dir(
            "unsaved",
            scratch_session,
            ("buffer-%d-%d.typ"):format(bufnr, scratch_id)
        )
    )
    pcall(vim.api.nvim_buf_set_var, bufnr, "typst_scratch_path", scratch_path)
    return scratch_path
end

--- Classify how a file became associated with a project.
---@param path string File path being associated.
---@param main string Project main file path.
---@param resolution? table Buffer resolution metadata.
---@return string source Association source label.
function M.association_source_for(path, main, resolution)
    if util.same_path(path, main) then
        return "explicit"
    end

    if resolution and resolution.graph_source then
        return resolution.graph_source
    end

    local main_source = resolution and resolution.main_source
    if main_file.is_heuristic_source(main_source) then
        return "heuristic"
    end

    return "explicit"
end

--- Rebuild the project graph's file set from buffers and dependencies.
---@param project table Project state whose graph service is mutated.
function M.rebuild_files(project)
    local graph = services.graph(project)
    if not graph then
        return
    end

    graph_sources.reset_graph(graph)

    for bufnr in pairs(project.bufs or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local path = M.current_buffer_path(bufnr)
            if path then
                local resolution = project.resolutions
                    and project.resolutions[bufnr]
                graph_sources.add_to_graph(
                    graph,
                    path,
                    M.association_source_for(path, project.main, resolution)
                )
            end
        end
    end

    for path in pairs(graph_dependencies.get(project)) do
        if graph_sources.is_source_path(path) then
            graph_sources.add_to_graph(
                graph,
                path,
                graph_dependencies.source_for(project, path) or "compiler"
            )
        end
    end

    graph_sources.add_to_graph(graph, project.main, "explicit")
end

--- Create a new project state object.
---@param root string Project root path.
---@param main string Project main file path.
---@param key string Registry key for the project.
---@return table project New project state.
function M.new_project(root, main, key)
    local project = {
        key = key,
        root = root,
        main = main,
        services = services.new_state(),
        bufs = {},
        resolutions = {},
        last_resolution = nil,
        root_source = nil,
        main_source = nil,
    }
    return project
end

--- Resolve the current configured output path for a project.
---@param project table Project state with root/main paths.
---@return string path Output path from current config.
function M.output_path(project)
    return output_path_util.output_path(project, config.unsafe_get())
end

return M
