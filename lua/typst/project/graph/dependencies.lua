local graph_service = require("typst.project.services.graph")
local graph_sources = require("typst.project.graph.sources")
local util = require("typst.core.util")

local M = {}

--- Replace compiler-discovered dependency edges for a project.
---
--- Dependencies include assets and bibliographies as well as Typst source
--- files. This module owns invalidation inputs only; source indexing is rebuilt
--- separately by `project.graph.sources`/`project.model`.
---@param project table Project state.
---@param paths string[] Dependency paths.
---@param opts? table Options with `source`.
---@return boolean changed True when dependency path membership changed.
function M.replace(project, paths, opts)
    opts = opts or {}
    local source = opts.source or "compiler"
    local graph = graph_service.get(project) or {}
    local previous_dependencies = graph.dependencies or {}
    local previous_sources = graph.dependency_sources or {}
    local dependencies = {}
    local dependency_sources = {}

    for _, path in ipairs(paths or {}) do
        local normalized = util.normalize(path)
        local next_source = util.same_path(path, project.main) and "explicit"
            or source
        dependencies[normalized] = true
        dependency_sources[normalized] = graph_sources.strongest_source(
            previous_sources[normalized],
            next_source
        )
    end

    dependencies[project.main] = true
    dependency_sources[project.main] = "explicit"
    local changed =
        not graph_sources.same_key_set(previous_dependencies, dependencies)
    graph_service.set(project, {
        dependencies = dependencies,
        dependency_sources = dependency_sources,
    })
    return changed
end

--- Return current dependency set for a project graph.
---@param project table Project state.
---@return table dependencies Dependency path set.
function M.get(project)
    return (graph_service.get(project) or {}).dependencies or {}
end

--- Return the source label for a dependency path.
---@param project table Project state.
---@param path string Dependency path.
---@return string? source Dependency source label.
function M.source_for(project, path)
    return ((graph_service.get(project) or {}).dependency_sources or {})[path]
end

--- Match a path against dependencies using normalized path keys.
---@param project table Project state.
---@param path string Path to match.
---@param path_key? string Precomputed path key.
---@return string? matched Matched graph path.
function M.match_path(project, path, path_key)
    local dependencies = M.get(project)
    if dependencies[path] then
        return path
    end

    path_key = path_key or util.path_key(path)
    for candidate in pairs(dependencies) do
        if util.path_key(candidate) == path_key then
            return candidate
        end
    end
end

return M
