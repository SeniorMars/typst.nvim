-- Compatibility facade over typed project services.
--
-- New subsystem code should prefer the smallest typed service module it owns,
-- while older callers can keep using this facade during migration. Typed
-- modules must only mutate their own service table; intentional cross-service
-- state such as "this PDF is now the active compiler output" belongs at the
-- workflow/coordinator call site.
local M = {}

local artifacts = require("typst.project.services.artifacts")
local compiler = require("typst.project.services.compiler")
local diagnostics = require("typst.project.services.diagnostics")
local graph = require("typst.project.services.graph")
local index = require("typst.project.services.index")
local invalidation = require("typst.project.services.invalidation")
local operations = require("typst.project.services.operation_state")
local preview = require("typst.project.services.preview")
local viewer = require("typst.project.services.viewer")

---@class TypstProjectServices
---@field operations TypstProjectOperationsService
---@field compiler TypstProjectCompilerService
---@field diagnostics TypstProjectDiagnosticsService
---@field preview TypstProjectPreviewService
---@field artifacts TypstProjectArtifactsService
---@field graph TypstProjectGraphService
---@field index TypstProjectIndexService
---@field viewer table
---@field invalidation TypstProjectInvalidationService

---@class TypstProjectOperationsService
---@field active_by_id table<integer, table>
---@field active_by_kind table<string, table>
---@field retained_by_id table<integer, table>
---@field retained_by_kind table<string, table>
---@field generations table<string, integer>
---@field last table<string, table>
---@field next_id integer

---@class TypstProjectCompilerService
---@field status string
---@field generation integer
---@field watch_generation integer
---@field watch_cycle_generation integer
---@field output string?
---@field output_lease table?
---@field process any?
---@field watcher any?
---@field process_operation table?
---@field watcher_operation table?
---@field last_result TypstCompilerResult?
---@field last_profile string?

---@class TypstProjectDiagnosticsService
---@field buffers table

---@class TypstProjectPreviewService
---@field active boolean

---@class TypstProjectArtifactsService
---@field items table
---@field output string?

---@class TypstProjectGraphService
---@field files table<string, table|boolean>
---@field file_sources table<string, table>
---@field dependencies table<string, table|boolean>
---@field dependency_sources table<string, table>

---@class TypstProjectIndexService
---@field files table<string, table>
---@field bibliographies table<string, table>
---@field graph table
---@field generation integer?

---@class TypstProjectInvalidationService
---@field generation integer
---@field counters table<string, integer>
---@field subscribers table
---@field history table

local service_modules = {
    operations = operations,
    compiler = compiler,
    diagnostics = diagnostics,
    preview = preview,
    artifacts = artifacts,
    graph = graph,
    index = index,
    viewer = viewer,
    invalidation = invalidation,
}

--- Create the per-project service state container.
---@return TypstProjectServices services Fresh project service state.
function M.new_state()
    return {
        operations = operations.defaults(),
        compiler = compiler.defaults(),
        diagnostics = diagnostics.defaults(),
        preview = preview.defaults(),
        artifacts = artifacts.defaults(),
        graph = graph.defaults(),
        index = index.defaults(),
        viewer = viewer.defaults(),
        invalidation = invalidation.defaults(),
    }
end

--- Ensure a project has all service tables initialized.
---@param project table? Project state to initialize.
---@return table? services Project service state, or nil for invalid input.
function M.ensure(project)
    if type(project) ~= "table" then
        return nil
    end

    if type(project.services) ~= "table" then
        project.services = M.new_state()
    end

    for _, module in pairs(service_modules) do
        module.ensure(project)
    end

    return project.services
end

--- Merge fields into the project compiler service.
---@param project table Project state whose compiler service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? compiler Compiler service table.
function M.set_compiler(project, fields)
    return compiler.set(project, fields)
end

--- Merge fields into the project preview service.
---@param project table Project state whose preview service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? preview Preview service table.
function M.set_preview(project, fields)
    return preview.set(project, fields)
end

--- Merge fields into the project artifact service.
---@param project table Project state whose artifact service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? artifacts Artifact service table.
function M.set_artifacts(project, fields)
    return artifacts.set(project, fields)
end

--- Merge fields into the project diagnostics service.
---@param project table Project state whose diagnostics service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? diagnostics Diagnostics service table.
function M.set_diagnostics(project, fields)
    return diagnostics.set(project, fields)
end

--- Merge fields into the project dependency graph service.
---@param project table Project state whose graph service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? graph Graph service table.
function M.set_graph(project, fields)
    return graph.set(project, fields)
end

--- Merge fields into the project viewer service.
---@param project table Project state whose viewer service is mutated.
---@param fields table Fields to set; `clear`/`_clear` removes keys first.
---@return table? viewer Viewer service table.
function M.set_viewer(project, fields)
    return viewer.set(project, fields)
end

--- Return the diagnostics service for a project.
---@param project table Project state to inspect.
---@return table? diagnostics Diagnostics service table.
function M.diagnostics(project)
    return diagnostics.get(project)
end

--- Return the compiler service for a project.
---@param project table Project state to inspect.
---@return table? compiler Compiler service table.
function M.compiler(project)
    return compiler.get(project)
end

--- Return the operation tracking service for a project.
---@param project table Project state to inspect.
---@return table? operations Operation service table.
function M.operations(project)
    return operations.get(project)
end

--- Return the preview service for a project.
---@param project table Project state to inspect.
---@return table? preview Preview service table.
function M.preview(project)
    return preview.get(project)
end

--- Return the artifact service for a project.
---@param project table Project state to inspect.
---@return table? artifacts Artifact service table.
function M.artifacts(project)
    return artifacts.get(project)
end

--- Return the dependency graph service for a project.
---@param project table Project state to inspect.
---@return table? graph Graph service table.
function M.graph(project)
    return graph.get(project)
end

--- Return the index cache service for a project.
---@param project table Project state to inspect.
---@return table? index Index service table.
function M.index(project)
    return index.get(project)
end

--- Return the viewer service for a project.
---@param project table Project state to inspect.
---@return table? viewer Viewer service table.
function M.viewer(project)
    return viewer.get(project)
end

--- Return the invalidation bus service for a project.
---@param project table Project state to inspect.
---@return table? invalidation Invalidation service table.
function M.invalidation(project)
    return invalidation.get(project)
end

--- Check whether a project still owns processes, preview, or active operations.
---@param project table Project state to inspect.
---@return boolean active True when pruning should keep the project alive.
function M.has_active_resources(project)
    local services = M.ensure(project)
    if not services then
        return false
    end

    return compiler.has_active(services.compiler)
        or services.preview.active == true
        or next(services.operations.active_by_id or {}) ~= nil
        or next(services.operations.retained_by_id or {}) ~= nil
end

--- Return a summary-safe snapshot of project service state.
---@param project table Project state to snapshot.
---@return table? snapshot Snapshot suitable for reports/tests.
function M.snapshot(project)
    if not M.ensure(project) then
        return nil
    end

    return {
        operations = operations.snapshot(project),
        compiler = compiler.snapshot(project),
        preview = preview.snapshot(project),
        artifacts = artifacts.snapshot(project),
        graph = graph.snapshot(project),
        viewer = viewer.snapshot(project),
        invalidation = invalidation.snapshot(project),
        diagnostics = diagnostics.snapshot(project),
        index = index.snapshot(project),
    }
end

return M
