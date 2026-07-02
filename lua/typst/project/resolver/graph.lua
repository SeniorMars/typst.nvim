local graph_match = require("typst.project.graph_match")
local log = require("typst.core.log")
local main_sources = require("typst.project.resolver.main")
local project_store = require("typst.project.store")

local M = {}

---Resolve against already-known project dependency graphs.
---@param bufnr integer Buffer being resolved.
---@param path string Buffer path.
---@param resolve_opts table Resolver controls.
---@return table? candidate Existing-project candidate, if one matched.
function M.existing_project(bufnr, path, resolve_opts)
    local existing, ambiguous, graph_source = graph_match.existing_project_for(
        project_store.all(),
        path,
        resolve_opts.ignore_project_key
    )
    if existing then
        return {
            bufnr = bufnr,
            path = path,
            root = existing.root,
            main = existing.main,
            previous_key = project_store.key_for_buffer(bufnr),
            resolution = {
                root_source = "existing project",
                main_source = "existing project graph",
                main_confidence = existing.main_confidence
                    or main_sources.confidence_for_source(
                        "existing project graph"
                    ),
                main_confidence_source = existing.main_confidence_source
                    or existing.main_source
                    or "existing project graph",
                graph_source = graph_source or "unknown",
            },
        }
    end

    if ambiguous then
        log.add(
            "info",
            "project graph attachment was ambiguous; continuing resolver fallbacks",
            { path = path }
        )
    end
end

return M
