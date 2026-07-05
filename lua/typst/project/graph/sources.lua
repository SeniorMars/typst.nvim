local graph_service = require("typst.project.services.graph")
local util = require("typst.core.util")

local M = {}

local source_priority = {
    explicit = 3,
    compiler = 2,
    heuristic = 1,
}

--- Return true when a path should be scanned as Typst source.
---@param path any Path to classify.
---@return boolean source True for source-like Typst files.
function M.is_source_path(path)
    return type(path) == "string" and path:lower():match("%.typ$") ~= nil
end

--- Return the precedence of a project association source.
---@param source? string Association source label.
---@return integer priority Higher values win.
function M.source_priority(source)
    return source_priority[source] or 0
end

--- Choose the stronger project association source.
---@param current? string Existing source label.
---@param incoming? string Incoming source label.
---@return string? source Stronger source label.
function M.strongest_source(current, incoming)
    if current == nil then
        return incoming
    end

    local current_priority = M.source_priority(current)
    local incoming_priority = M.source_priority(incoming)
    if current_priority >= incoming_priority then
        return current
    end

    return incoming
end

--- Compare two set-like tables by key membership.
---@param left? table First set-like table.
---@param right? table Second set-like table.
---@return boolean same True when both tables contain the same keys.
function M.same_key_set(left, right)
    left = left or {}
    right = right or {}

    for key in pairs(left) do
        if not right[key] then
            return false
        end
    end

    for key in pairs(right) do
        if not left[key] then
            return false
        end
    end

    return true
end

--- Clear source-file state on a graph service table.
---@param graph table Graph service table.
---@return table graph The same graph table.
function M.reset_graph(graph)
    graph.files = {}
    graph.file_sources = {}
    return graph
end

--- Add a source file to a graph service table.
---@param graph table Graph service table.
---@param path string File path to add.
---@param source? string Association source label.
---@return string? normalized Normalized path that was added.
function M.add_to_graph(graph, path, source)
    if not graph or type(path) ~= "string" or path == "" then
        return nil
    end

    local normalized = util.normalize(path)
    graph.files = graph.files or {}
    graph.file_sources = graph.file_sources or {}
    graph.files[normalized] = true
    graph.file_sources[normalized] =
        M.strongest_source(graph.file_sources[normalized], source or "explicit")
    return normalized
end

--- Add a source file to a project graph.
---@param project table Project state.
---@param path string File path to add.
---@param source? string Association source label.
---@return table? graph Graph service table.
function M.add(project, path, source)
    local graph = graph_service.get(project)
    if not graph then
        return nil
    end
    M.add_to_graph(graph, path, source)
    return graph
end

--- Return current source-file set for a project graph.
---@param project table Project state.
---@return table files Source path set.
function M.get(project)
    return (graph_service.get(project) or {}).files or {}
end

--- Return the source label for a project source file.
---@param project table Project state.
---@param path string Source file path.
---@return string? source Source label.
function M.source_for(project, path)
    return ((graph_service.get(project) or {}).file_sources or {})[path]
end

--- Match a path against source files using normalized path keys.
---@param project table Project state.
---@param path string Path to match.
---@param path_key? string Precomputed path key.
---@return string? matched Matched graph path.
function M.match_path(project, path, path_key)
    local files = M.get(project)
    if files[path] then
        return path
    end

    path_key = path_key or util.path_key(path)
    for candidate in pairs(files) do
        if util.path_key(candidate) == path_key then
            return candidate
        end
    end
end

return M
