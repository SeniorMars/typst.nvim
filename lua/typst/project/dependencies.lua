local project_model = require("typst.project.model")
local graph_dependencies = require("typst.project.graph.dependencies")

local M = {}

-- Maintains compiler-discovered dependency edges for a project.
--
-- Typst's dependency file is stronger evidence than the static import scan, but
-- the main file remains explicit so graph rebuilds cannot drop the root
-- document when a compiler run reports only secondary inputs.
local mark_index_dirty = project_model.mark_index_dirty
local rebuild_files = project_model.rebuild_files

function M.update(project, paths, opts)
    local changed = graph_dependencies.replace(project, paths, opts)
    rebuild_files(project)
    if changed then
        mark_index_dirty(project, "dependency graph changed")
    end
end

return M
