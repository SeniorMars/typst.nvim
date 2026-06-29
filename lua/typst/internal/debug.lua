local operation = require("typst.core.operation")
local path_leases = require("typst.core.path_leases")
local project_registry = require("typst.project")
local project_services = require("typst.project.services")
local telemetry = require("typst.core.telemetry")

local M = {}

local function add(findings, code, message, fields)
    findings[#findings + 1] = vim.tbl_extend("force", {
        code = code,
        message = message,
    }, fields or {})
end

local function check_project_buffers(findings, projects)
    local owners = {}
    for key, project in pairs(projects) do
        for bufnr in pairs(project.bufs or {}) do
            owners[bufnr] = owners[bufnr] or {}
            owners[bufnr][#owners[bufnr] + 1] = key

            local attached = project_registry.get(bufnr)
            if attached ~= project then
                add(
                    findings,
                    "buffer_registry_mismatch",
                    "attached buffer does not resolve back to owning project",
                    { bufnr = bufnr, project = key }
                )
            end
        end
    end

    for bufnr, keys in pairs(owners) do
        if #keys > 1 then
            add(
                findings,
                "buffer_multiple_projects",
                "buffer belongs to more than one project",
                { bufnr = bufnr, projects = keys }
            )
        end
    end
end

local function check_project_resources(findings, projects)
    for key, project in pairs(projects) do
        local services = project_services.ensure(project)
        local compiler = services.compiler or {}
        local operations = services.operations or {}
        if
            next(project.bufs or {}) == nil
            and project_services.has_active_resources(project) == false
            and (
                compiler.process
                or compiler.watcher
                or compiler.stopping_compile
                or next(operations.active_by_id or {}) ~= nil
                or next(operations.retained_by_id or {}) ~= nil
            )
        then
            add(
                findings,
                "unowned_project_resource",
                "project has resource fields but active-resource check is false",
                { project = key }
            )
        end
    end
end

local function check_operations(findings)
    for id, record in pairs(operation.active()) do
        if record.state == "finished" then
            add(
                findings,
                "finished_operation_active",
                "finished operation remains in active registry",
                { operation = id, kind = record.kind }
            )
        end
    end
    for id, record in pairs(operation.retained()) do
        if record.state ~= "orphaned-retained" then
            add(
                findings,
                "invalid_retained_operation",
                "retained operation is not marked orphaned-retained",
                { operation = id, kind = record.kind, state = record.state }
            )
        end
    end
end

local function check_leases(findings)
    for key, lease in pairs(path_leases.active()) do
        if type(lease.owner) ~= "table" or not lease.owner.kind then
            add(
                findings,
                "lease_missing_owner",
                "path lease has no owner metadata",
                { path = lease.path, key = key }
            )
        end
    end
end

local function check_diagnostic_namespaces(findings, projects)
    local seen = {}
    for key, project in pairs(projects) do
        for source, namespace in pairs(project.diagnostics_namespaces or {}) do
            local previous = seen[namespace]
            if previous then
                add(
                    findings,
                    "diagnostic_namespace_shared",
                    "diagnostic namespace is shared by multiple project sources",
                    {
                        namespace = namespace,
                        project = key,
                        source = source,
                        previous = previous,
                    }
                )
            else
                seen[namespace] = { project = key, source = source }
            end
        end
    end
end

function M.check_invariants()
    local findings = {}
    local projects = project_registry.all()

    check_project_buffers(findings, projects)
    check_project_resources(findings, projects)
    check_operations(findings)
    check_leases(findings)
    check_diagnostic_namespaces(findings, projects)

    return {
        ok = #findings == 0,
        findings = findings,
        projects = vim.tbl_count(projects),
        active_operations = vim.tbl_count(operation.active()),
        retained_operations = vim.tbl_count(operation.retained()),
        active_leases = vim.tbl_count(path_leases.active()),
    }
end

function M.telemetry()
    return telemetry.snapshot()
end

function M.telemetry_report()
    return telemetry.report()
end

function M.reset_telemetry()
    telemetry.reset()
end

return M
