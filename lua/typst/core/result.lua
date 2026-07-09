local M = {}

-- Shared result-shape helpers for async/compiler/provider/resource lifecycle
-- code. Subsystems may add domain-specific fields, but these predicates define
-- the common meanings of pending, stopped, idle, timeout, and orphaned.
M.reason = {
    already_stopped = "already_stopped",
    cancel_failed = "cancel_failed",
    cancel_unconfirmed = "cancel_unconfirmed",
    cancelled = "cancelled",
    finish_subscription_failed = "finish_subscription_failed",
    idle = "idle",
    no_active = "no_active",
    not_active = "not_active",
    orphaned = "orphaned",
    pending_complete_failed = "pending_complete_failed",
    provider_not_started = "provider_not_started",
    project_changed = "project_changed",
    reset = "reset",
    shutdown_failed = "shutdown_failed",
    stale_preview_open = "stale_preview_open",
    stop_failed = "stop_failed",
    timeout = "timeout",
    unconfirmed_stop = "unconfirmed_stop",
}

M.status = {
    failed = "failed",
    idle = "idle",
    pending = "pending",
    stale = "stale",
    stopped = "stopped",
}

local function merge(fields, defaults)
    return vim.tbl_extend("force", defaults or {}, fields or {})
end

function M.ok(fields)
    return merge(fields, {
        ok = true,
        pending = false,
        stale = false,
        code = 0,
    })
end

function M.failed(reason, message, fields)
    return merge(fields, {
        ok = false,
        pending = false,
        code = 1,
        reason = reason,
        message = message or reason,
    })
end

function M.fail(reason, fields)
    return M.failed(reason or "failed", fields and fields.message or nil, fields)
end

function M.pending(kind, fields)
    return merge(fields, {
        ok = false,
        pending = true,
        kind = kind,
    })
end

function M.stale(reason, fields)
    return merge(fields, {
        ok = false,
        pending = false,
        stale = true,
        reason = reason or "stale_result",
        message = "operation result is stale",
    })
end

function M.timeout(fields)
    return M.failed(M.reason.timeout, "operation timed out", merge(fields, {
        timeout = true,
        stopped = false,
    }))
end

function M.stopped(fields)
    return merge(fields, {
        ok = true,
        pending = false,
        code = 0,
        stopped = true,
    })
end

function M.idle(fields)
    local result = merge(fields, {
        ok = true,
        code = 0,
    })
    result.idle = true
    result.stopped = true
    return result
end

function M.cancelled(fields)
    return merge(fields, {
        ok = false,
        pending = false,
        code = 1,
        stopped = false,
        reason = M.reason.cancelled,
    })
end

function M.orphaned(fields)
    return merge(fields, {
        ok = false,
        pending = true,
        code = 1,
        stopped = false,
        orphaned = true,
        reason = M.reason.orphaned,
        message = "operation process could not be confirmed stopped",
    })
end

function M.retained(fields)
    return merge(fields, {
        ok = false,
        pending = false,
        code = 1,
        stopped = false,
        orphaned = true,
        retained = true,
        reason = M.reason.orphaned,
        message = "operation retained after failed termination",
    })
end

function M.is_pending(result)
    return type(result) == "table" and result.pending == true
end

function M.is_idle(result)
    return type(result) == "table" and result.idle == true
end

function M.is_confirmed_stopped(result)
    if result == true then
        return true
    end
    return type(result) == "table"
        and result.stopped ~= false
        and (result.stopped == true or result.idle == true)
end

function M.is_unconfirmed_stop(result)
    if type(result) ~= "table" or result.stopped == true then
        return false
    end
    if result._typst_unconfirmed_stop == true then
        return true
    end
    if result.stopped == false then
        return result.idle == true
            or result.pending == true
            or result.orphaned == true
            or result.reason == M.reason.timeout
            or result.reason == M.reason.unconfirmed_stop
            or result.reason == M.reason.orphaned
            or result.reason == M.reason.cancelled
            or result.reason == M.reason.cancel_failed
            or result.reason == M.reason.shutdown_failed
            or result.reason == M.reason.stop_failed
    end
    return result.idle ~= true
        and (
            result.pending == true
            or result.reason == M.reason.timeout
            or result.orphaned == true
        )
end

function M.is_terminal(result)
    return type(result) ~= "table" or result.pending ~= true
end

function M.normalize_compiler(result, invalid_message)
    if type(result) ~= "table" then
        return M.failed(
            "invalid_result",
            result == nil
                    and (invalid_message or "Compiler provider returned no result")
                or tostring(result),
            {
                stdout = "",
                stderr = result == nil and "" or tostring(result),
                stale = false,
            }
        )
    end

    if result.stdout == nil then
        result.stdout = ""
    elseif type(result.stdout) ~= "string" then
        result.stdout = tostring(result.stdout)
    end
    if result.stderr == nil then
        result.stderr = ""
    elseif type(result.stderr) ~= "string" then
        result.stderr = tostring(result.stderr)
    end
    if result.idle == true and result.stopped == false then
        result.idle = false
        result.reason = result.reason or M.reason.unconfirmed_stop
        result.message = result.message or "stop could not be confirmed"
        result.ok = false
        result.code = 1
    elseif result.idle == true and result.stopped == nil then
        result.stopped = true
    end

    if result.code == nil then
        if result.ok == true then
            result.code = 0
        elseif result.ok == false then
            result.code = 1
        elseif result.stopped or result.idle then
            result.code = (
                result.error or result.reason == M.reason.timeout
            ) and 1 or 0
        elseif result.error or result.reason then
            result.code = 1
        end
    end

    if result.code ~= nil and result.ok == nil then
        result.ok = result.code == 0
    end
    if result.stale == nil then
        result.stale = false
    end
    return result
end

function M.stop_allows_restart(result)
    if result == nil or result == true then
        return true
    end

    if result == false or type(result) ~= "table" then
        return false
    end

    local reason = result.reason
    if
        result.idle == true
        or reason == M.reason.idle
        or reason == M.reason.not_active
        or reason == M.reason.no_active
        or reason == M.reason.already_stopped
        or reason == M.reason.provider_not_started
    then
        return result.ok ~= false and result.stopped ~= false
    end

    if result.ok == false or result.stopped == false then
        return false
    end

    if result.stopped == true then
        return true
    end

    return result.ok == true or result.code == 0
end

return M
