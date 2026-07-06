local attachment_index = require("typst.project.attachments.index")
local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local graph_service = require("typst.project.services.graph")
local log = require("typst.core.log")
local project_model = require("typst.project.model")
local project_store = require("typst.project.store")
local service_base = require("typst.project.services.base")

local M = {}

local function copy_value(value, depth)
    return service_base.copy_value(value, depth or 5)
end

local function diagnostics_module()
    return require("typst.diagnostics")
end

local function replace_table(target, snapshot)
    for key in pairs(target or {}) do
        target[key] = nil
    end
    for key, value in pairs(snapshot or {}) do
        target[key] = value
    end
    return target
end

local function snapshot_project(project, bufnr)
    local compiler = compiler_service.get(project) or {}
    local diagnostics = diagnostics_service.get(project) or {}

    return {
        project = project,
        key = project.key,
        bufs = project.bufs,
        bufs_present = project.bufs and project.bufs[bufnr] ~= nil,
        bufs_value = project.bufs and project.bufs[bufnr],
        resolutions = project.resolutions,
        resolution_present = project.resolutions
            and project.resolutions[bufnr] ~= nil,
        resolution = copy_value(
            project.resolutions and project.resolutions[bufnr],
            6
        ),
        last_resolution = copy_value(project.last_resolution, 6),
        root_source = project.root_source,
        main_source = project.main_source,
        main_confidence = project.main_confidence,
        main_confidence_source = project.main_confidence_source,
        source_kind = project.source_kind,
        scratch = project.scratch,
        graph = graph_service.snapshot(project),
        diagnostics = copy_value(diagnostics, 6),
        neovim_diagnostics = diagnostics_module().snapshot_buffer(
            project,
            bufnr
        ),
        compiler_output_present = compiler.output ~= nil,
        compiler_output = compiler.output,
        compiler_outputless_present = compiler.outputless ~= nil,
        compiler_outputless = compiler.outputless,
        pruned = project._typst_project_pruned,
        pruned_reason = project._typst_project_pruned_reason,
        pruned_event_emitted = project._typst_project_pruned_event_emitted,
    }
end

local function restore_project(snapshot, bufnr)
    local project = snapshot.project
    project_store.restore(project)

    project.bufs = snapshot.bufs or project.bufs or {}
    if snapshot.bufs_present then
        project.bufs[bufnr] = snapshot.bufs_value
    else
        project.bufs[bufnr] = nil
    end

    project.resolutions = snapshot.resolutions or project.resolutions or {}
    if snapshot.resolution_present then
        project.resolutions[bufnr] = copy_value(snapshot.resolution, 6)
    else
        project.resolutions[bufnr] = nil
    end

    project.last_resolution = copy_value(snapshot.last_resolution, 6)
    project.root_source = snapshot.root_source
    project.main_source = snapshot.main_source
    project.main_confidence = snapshot.main_confidence
    project.main_confidence_source = snapshot.main_confidence_source
    project.source_kind = snapshot.source_kind
    project.scratch = snapshot.scratch
    project._typst_project_pruned = snapshot.pruned
    project._typst_project_pruned_reason = snapshot.pruned_reason
    project._typst_project_pruned_event_emitted = snapshot.pruned_event_emitted

    replace_table(
        graph_service.ensure(project),
        copy_value(snapshot.graph or graph_service.defaults(), 6)
    )
    replace_table(
        diagnostics_service.ensure(project),
        copy_value(snapshot.diagnostics or diagnostics_service.defaults(), 6)
    )

    local compiler = compiler_service.ensure(project)
    if snapshot.compiler_output_present then
        compiler.output = snapshot.compiler_output
    else
        compiler.output = nil
    end
    if snapshot.compiler_outputless_present then
        compiler.outputless = snapshot.compiler_outputless
    else
        compiler.outputless = nil
    end

    diagnostics_module().restore_buffer_snapshot(
        bufnr,
        snapshot.neovim_diagnostics
    )
    project_model.refresh_resolution_pending(project)
    project_model.rebuild_files(project)
end

local function snapshot_quickfix()
    local ok, quickfix = pcall(vim.fn.getqflist, { all = 1 })
    return ok and quickfix or nil
end

local function restore_quickfix(snapshot)
    if type(snapshot) == "table" then
        pcall(vim.fn.setqflist, {}, " ", snapshot)
    end
end

--- Begin a synchronous project-registry commit transaction.
---
--- The transaction captures every live project plus the target buffer mapping
--- before `create_or_update()` mutates registry, graph, diagnostics, compiler
--- output, or debounce state. It intentionally does not deep-copy live process
--- handles; only the output field this commit path may replace is restored.
---@param bufnr integer Buffer whose attachment is being committed.
---@return table transaction Transaction handle for `commit` or `rollback`.
function M.begin(bufnr)
    local projects = {}
    for key, project in pairs(project_store.all()) do
        projects[key] = snapshot_project(project, bufnr)
    end

    return {
        bufnr = bufnr,
        buffer_key = project_store.key_for_buffer(bufnr),
        projects = projects,
        dirty_ticks = attachment_index.snapshot(bufnr),
        quickfix = snapshot_quickfix(),
        active = true,
    }
end

---@param transaction table? Transaction returned by `begin`.
function M.commit(transaction)
    if type(transaction) == "table" then
        transaction.active = false
    end
end

--- Roll back a failed project-registry commit transaction.
---@param transaction table? Transaction returned by `begin`.
---@param opts? {reason?: string} Rollback metadata.
---@return boolean ok True when rollback completed.
---@return string? err Rollback error when any restoration step failed.
function M.rollback(transaction, opts)
    if type(transaction) ~= "table" or transaction.active ~= true then
        return true, nil
    end

    opts = opts or {}
    local errors = {}
    local function capture(label, fn)
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            errors[#errors + 1] = ("%s: %s"):format(label, tostring(err))
        end
    end

    capture("remove new projects", function()
        for key, project in pairs(project_store.all()) do
            if transaction.projects[key] == nil then
                project_store.remove(key)
                project._typst_project_pruned = true
                project._typst_project_pruned_reason = opts.reason
                    or "project commit rollback"
            end
        end
    end)

    for key, snapshot in pairs(transaction.projects) do
        capture("restore project " .. tostring(key), function()
            restore_project(snapshot, transaction.bufnr)
        end)
    end

    capture("restore buffer mapping", function()
        if transaction.buffer_key then
            project_store.set_buffer(transaction.bufnr, transaction.buffer_key)
        else
            project_store.clear_buffer(transaction.bufnr)
        end
    end)

    capture("restore dirty tick debounce", function()
        attachment_index.restore(transaction.bufnr, transaction.dirty_ticks)
    end)

    capture("restore quickfix", function()
        restore_quickfix(transaction.quickfix)
    end)

    transaction.active = false

    if #errors > 0 then
        local message = table.concat(errors, "\n")
        log.add("error", "project commit transaction rollback failed", {
            bufnr = transaction.bufnr,
            error = message,
        })
        return false, message
    end

    return true, nil
end

return M
