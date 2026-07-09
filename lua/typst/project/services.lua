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
local integrations = require("typst.project.services.integrations")
local invalidation = require("typst.project.services.invalidation")
local lifecycle = require("typst.project.services.lifecycle")
local operations = require("typst.project.services.operation_state")
local preview = require("typst.project.services.preview")
local viewer = require("typst.project.services.viewer")

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
    integrations = integrations,
    lifecycle = lifecycle,
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
        integrations = integrations.defaults(),
        lifecycle = lifecycle.defaults(),
    }
end

--- Ensure a project has all service tables initialized.
---@param project TypstProject? Project state to initialize.
---@return TypstProjectServices? services Project service state, or nil for invalid input.
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
---@param project TypstProject Project state whose compiler service is mutated.
---@param fields TypstProjectCompilerServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectCompilerService? compiler Compiler service table.
function M.set_compiler(project, fields)
    return compiler.set(project, fields)
end

--- Merge fields into the project preview service.
---@param project TypstProject Project state whose preview service is mutated.
---@param fields TypstProjectPreviewServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectPreviewService? preview Preview service table.
function M.set_preview(project, fields)
    return preview.set(project, fields)
end

--- Merge fields into the project artifact service.
---@param project TypstProject Project state whose artifact service is mutated.
---@param fields TypstProjectArtifactsServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectArtifactsService? artifacts Artifact service table.
function M.set_artifacts(project, fields)
    return artifacts.set(project, fields)
end

--- Merge fields into the project diagnostics service.
---@param project TypstProject Project state whose diagnostics service is mutated.
---@param fields TypstProjectDiagnosticsServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectDiagnosticsService? diagnostics Diagnostics service table.
function M.set_diagnostics(project, fields)
    return diagnostics.set(project, fields)
end

--- Merge fields into the project dependency graph service.
---@param project TypstProject Project state whose graph service is mutated.
---@param fields TypstProjectGraphServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectGraphService? graph Graph service table.
function M.set_graph(project, fields)
    return graph.set(project, fields)
end

--- Merge fields into the project viewer service.
---@param project TypstProject Project state whose viewer service is mutated.
---@param fields TypstProjectViewerServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectViewerService? viewer Viewer service table.
function M.set_viewer(project, fields)
    return viewer.set(project, fields)
end

--- Return the diagnostics service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectDiagnosticsService? diagnostics Diagnostics service table.
function M.diagnostics(project)
    return diagnostics.get(project)
end

--- Return the compiler service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectCompilerService? compiler Compiler service table.
function M.compiler(project)
    return compiler.get(project)
end

--- Return the operation tracking service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectOperationsService? operations Operation service table.
function M.operations(project)
    return operations.get(project)
end

--- Return the preview service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectPreviewService? preview Preview service table.
function M.preview(project)
    return preview.get(project)
end

--- Return the artifact service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectArtifactsService? artifacts Artifact service table.
function M.artifacts(project)
    return artifacts.get(project)
end

--- Return the dependency graph service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectGraphService? graph Graph service table.
function M.graph(project)
    return graph.get(project)
end

--- Return the index cache service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectIndexService? index Index service table.
function M.index(project)
    return index.get(project)
end

--- Return the viewer service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectViewerService? viewer Viewer service table.
function M.viewer(project)
    return viewer.get(project)
end

--- Return the invalidation bus service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectInvalidationService? invalidation Invalidation service table.
function M.invalidation(project)
    return invalidation.get(project)
end

--- Return the integration status service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectIntegrationsService? integrations Integration service table.
function M.integrations(project)
    return integrations.get(project)
end

--- Return the lifecycle status service for a project.
---@param project TypstProject Project state to inspect.
---@return TypstProjectLifecycleService? lifecycle Lifecycle service table.
function M.lifecycle(project)
    return lifecycle.get(project)
end

--- Check whether a project still owns processes, preview, or active operations.
---@param project TypstProject Project state to inspect.
---@return boolean active True when pruning should keep the project alive.
function M.has_active_resources(project)
    M.ensure(project)
    return require("typst.runtime.resource_manager").has_active_resources(
        project
    )
end

--- Return a summary-safe snapshot of project service state.
---@param project TypstProject Project state to snapshot.
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
        integrations = integrations.snapshot(project),
        lifecycle = lifecycle.snapshot(project),
    }
end

return M
