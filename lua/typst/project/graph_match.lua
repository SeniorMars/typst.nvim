local log = require("typst.core.log")
local graph_dependencies = require("typst.project.graph.dependencies")
local graph_sources = require("typst.project.graph.sources")
local util = require("typst.core.util")

local M = {}

-- Attach newly opened files to an existing project only when the dependency
-- graph gives one clear owner. Equal-priority matches are left unattached so a
-- buffer is not silently assigned to the wrong main document.

local function matching_path(project, path, path_key)
    return graph_dependencies.match_path(project, path, path_key)
        or graph_sources.match_path(project, path, path_key)
end

local function source_for(project, path)
    return graph_sources.source_for(project, path)
        or graph_dependencies.source_for(project, path)
        or (graph_dependencies.get(project)[path] and "compiler")
        or "explicit"
end

function M.existing_project_for(registry, path, ignore_key)
    local matched = nil
    local matched_source = nil
    local matched_priority = nil
    local ambiguous = false
    local path_key = util.path_key(path)

    for _, project in pairs(registry) do
        if project.key ~= ignore_key then
            local matched_path = matching_path(project, path, path_key)
            if matched_path then
                local source = source_for(project, matched_path)
                local priority = graph_sources.source_priority(source)

                if not matched or priority > matched_priority then
                    matched = project
                    matched_source = source
                    matched_priority = priority
                    ambiguous = false
                elseif priority == matched_priority then
                    ambiguous = true
                end
            end
        end
    end

    if ambiguous then
        log.add("info", "skipped ambiguous project graph attachment", {
            path = path,
        })
        return nil, true
    end

    return matched, false, matched_source
end

return M
