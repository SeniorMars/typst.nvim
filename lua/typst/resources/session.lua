local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local index_service = require("typst.project.services.index")
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

local function pid_for(handle)
    if type(handle) ~= "table" then
        return nil
    end
    if handle.pid then
        return handle.pid
    end
    if type(handle.handle) == "table" then
        return handle.handle.pid
    end
    return nil
end

local function kind_counts(records)
    local counts = {}
    for _, record in pairs(records or {}) do
        local kind = record.kind or "unknown"
        counts[kind] = (counts[kind] or 0) + 1
    end
    return counts
end

local function add(blockers, kind, severity, message, fields)
    fields = fields or {}
    fields.kind = kind
    fields.severity = severity
    fields.message = message
    blockers[#blockers + 1] = fields
end

function M.blockers(project)
    if type(project) ~= "table" then
        return {}
    end

    local blockers = {}
    local compiler = compiler_service.get(project) or {}
    local preview = preview_service.get(project) or {}
    local operations = operation_service.get(project) or {}
    local index = index_service.get(project) or {}
    local outputs = output_ownership.snapshot(project)
    local lock_failure = output_ownership.last_release_failure(project)

    if compiler.process then
        add(blockers, "compiler_process", "active", "compiler process active", {
            pid = pid_for(compiler.process),
        })
    end
    if compiler.watcher then
        add(blockers, "compiler_watcher", "active", "watcher active", {
            pid = pid_for(compiler.watcher),
        })
    end
    if compiler.stopping_compile then
        add(
            blockers,
            "compiler_stopping",
            "active",
            "compiler stop in progress"
        )
    end
    if compiler.status == "stopping_failed" then
        add(
            blockers,
            "compiler_stop_unconfirmed",
            "blocked",
            "compiler stop was not confirmed"
        )
    end
    if compiler.output_lease then
        add(
            blockers,
            "compiler_output_lease",
            "active",
            "compiler output lease retained",
            {
                path = compiler.output_lease.path,
            }
        )
    end

    if preview.active == true then
        add(blockers, "preview_active", "active", "preview active", {
            backend = preview.active_backend or preview.last_backend,
            output = preview.active_output,
        })
    end
    if preview.stopping == true then
        add(blockers, "preview_stopping", "active", "preview stop in progress")
    end
    if preview.status == "stopping_failed" then
        add(
            blockers,
            "preview_stop_unconfirmed",
            "blocked",
            "preview stop was not confirmed"
        )
    end
    if preview.status == "open_failed" or preview.last_error then
        add(
            blockers,
            "preview_failed",
            "warning",
            "preview has a recorded failure",
            {
                reason = type(preview.last_error) == "table"
                        and preview.last_error.reason
                    or nil,
            }
        )
    end

    local active_count = count(operations.active_by_id)
    if active_count > 0 then
        add(blockers, "operation_active", "active", "operations active", {
            count = active_count,
            kinds = kind_counts(operations.active_by_id),
        })
    end
    local retained_count = count(operations.retained_by_id)
    if retained_count > 0 then
        add(
            blockers,
            "operation_retained",
            "blocked",
            "retained operations require cleanup",
            {
                count = retained_count,
                kinds = kind_counts(operations.retained_by_id),
            }
        )
    end

    if #outputs > 0 then
        add(blockers, "output_lease", "active", "output leases active", {
            count = #outputs,
            leases = outputs,
        })
    end
    if lock_failure then
        add(
            blockers,
            "output_lock_release_failed",
            "warning",
            "last output lock release failed",
            {
                reason = lock_failure.error,
                path = lock_failure.path,
                lock_path = lock_failure.lock_path,
            }
        )
    end

    if index.fs_watch_mode == "polling" and index.fs_watch_disabled_reason then
        add(
            blockers,
            "index_fs_watch_polling",
            "warning",
            "index file watchers are using polling",
            {
                reason = index.fs_watch_disabled_reason,
                active = index.fs_watch_active_count,
                wanted = index.fs_watch_wanted_count,
                cap = index.fs_watch_cap,
            }
        )
    end

    if project.resolution_pending then
        add(
            blockers,
            "resolution_pending",
            "active",
            "project resolution is pending",
            {
                reason = project.resolution_pending,
            }
        )
    end
    if project.main_confidence == "low" then
        add(
            blockers,
            "main_confidence_low",
            "warning",
            "main file resolution has low confidence",
            {
                source = project.main_confidence_source or project.main_source,
            }
        )
    end

    table.sort(blockers, function(left, right)
        return (left.kind or "") < (right.kind or "")
    end)
    return blockers
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
    local blockers = M.blockers(project)
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
        blockers = blockers,
        blocker_count = #blockers,
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
