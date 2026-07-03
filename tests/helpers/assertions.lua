local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local operation_service = require("typst.project.services.operation_state")
local output_ownership = require("typst.resources.outputs")

local M = {}

local function fail(message)
    error(message, 2)
end

function M.compiler_idle(project, message)
    local compiler = compiler_service.get(project) or {}
    if compiler_service.has_active(compiler) or compiler.status ~= "idle" then
        fail(message or "expected compiler to be idle")
    end
end

function M.compiler_inactive(project, message)
    local compiler = compiler_service.get(project) or {}
    if compiler_service.has_active(compiler) then
        fail(message or "expected compiler to have no active handles")
    end
end

function M.compiler_active_compile(project, message)
    local compiler = compiler_service.get(project) or {}
    if compiler.process == nil or compiler.status ~= "compiling" then
        fail(message or "expected active compiler process")
    end
end

function M.compiler_active_watch(project, message)
    local compiler = compiler_service.get(project) or {}
    if compiler.watcher == nil or compiler.status ~= "watching" then
        fail(message or "expected active compiler watcher")
    end
end

function M.no_output_leases(project, message)
    local leases = output_ownership.snapshot(project)
    if #leases ~= 0 then
        fail(message or ("expected no output leases, found " .. #leases))
    end
end

function M.output_lease(project, path, message)
    for _, lease in ipairs(output_ownership.snapshot(project)) do
        if lease.path == path then
            return lease
        end
    end
    fail(message or ("expected output lease for " .. tostring(path)))
end

function M.no_retained_operations(project, message)
    local operations = operation_service.get(project) or {}
    local count = vim.tbl_count(operations.retained_by_id or {})
    if count ~= 0 then
        fail(message or ("expected no retained operations, found " .. count))
    end
end

function M.retained_operation(project, record, message)
    local operations = operation_service.get(project) or {}
    if not record or operations.retained_by_id[record.id] ~= record then
        fail(message or "expected retained operation record")
    end
end

function M.diagnostics(project, source, count, message)
    local diagnostics = diagnostics_service.get(project) or {}
    local actual = 0
    for _, by_source in pairs(diagnostics.buffers or {}) do
        actual = actual + #(by_source[source] or {})
    end
    if actual ~= count then
        fail(
            message
                or ("expected " .. count .. " diagnostics, found " .. actual)
        )
    end
end

return M
