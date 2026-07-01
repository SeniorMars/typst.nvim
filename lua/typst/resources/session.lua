local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local operation_service = require("typst.project.services.operation_state")
local output_ownership = require("typst.resources.outputs")
local preview_service = require("typst.project.services.preview")

local M = {}

-- Project resource/session view. This does not own individual backends yet; it
-- centralizes the question every lifecycle path asks: what live resources does
-- this project still own?

local function count(table_value)
    return vim.tbl_count(table_value or {})
end

function M.snapshot(project)
    if type(project) ~= "table" then
        return nil
    end

    local compiler = compiler_service.get(project) or {}
    local preview = preview_service.get(project) or {}
    local operations = operation_service.get(project) or {}
    local diagnostics = diagnostics_service.get(project) or {}
    local outputs = output_ownership.active_for_project(project)

    return {
        compiler = {
            active = compiler_service.has_active(compiler),
            status = compiler.status,
            has_process = compiler.process ~= nil,
            has_watcher = compiler.watcher ~= nil,
            has_output_lease = compiler.output_lease ~= nil,
        },
        preview = {
            active = preview.active == true,
            status = preview.status,
            backend = preview.active_backend or preview.last_backend,
            stopping = preview.stopping == true,
        },
        operations = {
            active = count(operations.active_by_id),
            retained = count(operations.retained_by_id),
        },
        diagnostics = {
            buffers = count(diagnostics.buffers),
        },
        outputs = {
            active = count(outputs),
            leases = outputs,
        },
    }
end

function M.has_active(project)
    local snapshot = M.snapshot(project)
    if not snapshot then
        return false
    end

    return snapshot.compiler.active
        or snapshot.preview.active
        or snapshot.operations.active > 0
        or snapshot.operations.retained > 0
        or snapshot.outputs.active > 0
end

return M
