local M = {}

-- Shared result-shape helpers for async/compiler/provider/resource lifecycle
-- code. Subsystems may add domain-specific fields, but these predicates define
-- the common meanings of pending, stopped, idle, timeout, and orphaned.

local function merge(fields, defaults)
    return vim.tbl_extend("force", defaults or {}, fields or {})
end

function M.ok(fields)
    return merge(fields, {
        ok = true,
        code = 0,
    })
end

function M.failed(reason, message, fields)
    return merge(fields, {
        ok = false,
        code = 1,
        reason = reason,
        message = message or reason,
    })
end

function M.timeout(fields)
    return M.failed("timeout", "operation timed out", fields)
end

function M.stopped(fields)
    return merge(fields, {
        ok = true,
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
        code = 1,
        stopped = false,
        reason = "cancelled",
    })
end

function M.orphaned(fields)
    return merge(fields, {
        ok = false,
        code = 1,
        stopped = false,
        orphaned = true,
        reason = "orphaned",
        message = "operation process could not be confirmed stopped",
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
            or result.reason == "timeout"
            or result.reason == "unconfirmed_stop"
            or result.reason == "orphaned"
            or result.reason == "cancelled"
            or result.reason == "cancel_failed"
            or result.reason == "shutdown_failed"
            or result.reason == "stop_failed"
    end
    return result.idle ~= true
        and (
            result.pending == true
            or result.reason == "timeout"
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
        result.reason = result.reason or "unconfirmed_stop"
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
            result.code = (result.error or result.reason == "timeout") and 1
                or 0
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
        or reason == "idle"
        or reason == "not_active"
        or reason == "no_active"
        or reason == "already_stopped"
        or reason == "provider_not_started"
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
