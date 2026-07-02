local operation = require("typst.core.operation")
local output_ownership = require("typst.resources.outputs")
local project_registry = require("typst.project")
local project_store = require("typst.project.store")
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

            if not vim.api.nvim_buf_is_valid(bufnr) then
                add(
                    findings,
                    "invalid_project_buffer",
                    "project owns an invalid buffer",
                    { bufnr = bufnr, project = key }
                )
            end

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

local function check_buffer_mappings(findings, projects)
    for bufnr, key in pairs(project_store.buffers()) do
        local project = projects[key]
        if not project then
            add(
                findings,
                "buffer_mapping_missing_project",
                "buffer mapping points at a missing project",
                { bufnr = bufnr, project = key }
            )
        else
            if not vim.api.nvim_buf_is_valid(bufnr) then
                add(
                    findings,
                    "invalid_mapped_buffer",
                    "registry maps an invalid buffer to a project",
                    { bufnr = bufnr, project = key }
                )
            end
            if not (project.bufs or {})[bufnr] then
                add(
                    findings,
                    "buffer_mapping_missing_reverse_owner",
                    "buffer registry map is not mirrored by project.bufs",
                    { bufnr = bufnr, project = key }
                )
            end
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
    for key, lease in pairs(output_ownership.active()) do
        if type(lease.owner) ~= "table" or not lease.owner.kind then
            add(
                findings,
                "lease_missing_owner",
                "path lease has no owner metadata",
                { path = lease.path, key = key }
            )
        end
        if
            type(lease.owner) == "table"
            and type(lease.owner.project_key) == "string"
            and not project_store.get(lease.owner.project_key)
        then
            add(
                findings,
                "lease_unknown_project",
                "path lease references a project that is no longer registered",
                {
                    path = lease.path,
                    key = key,
                    project = lease.owner.project_key,
                    owner_kind = lease.owner.kind,
                }
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

local function check_follow_buffer_autocmds(findings)
    local ok, runtime_setup = pcall(require, "typst.runtime.setup")
    if not ok or runtime_setup.is_setup() then
        return
    end

    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
        group = "typst_nvim_preview_follow_buffer",
    })
    if autocmd_ok and #autocmds > 0 then
        add(
            findings,
            "follow_buffer_autocmd_after_reset",
            "follow-buffer autocmds remain after runtime setup was reset",
            { autocmds = #autocmds }
        )
    end
end

function M.check_invariants()
    local findings = {}
    local projects = project_registry.all()

    check_buffer_mappings(findings, projects)
    check_project_buffers(findings, projects)
    check_project_resources(findings, projects)
    check_operations(findings)
    check_leases(findings)
    check_diagnostic_namespaces(findings, projects)
    check_follow_buffer_autocmds(findings)

    return {
        ok = #findings == 0,
        findings = findings,
        errors = findings,
        warnings = {},
        projects = vim.tbl_count(projects),
        attached_buffers = vim.tbl_count(project_store.buffers()),
        active_operations = vim.tbl_count(operation.active()),
        retained_operations = vim.tbl_count(operation.retained()),
        active_leases = vim.tbl_count(output_ownership.active()),
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
