local capabilities = require("typst.preview.capabilities")

local M = {}

---Build a structured preview failure result.
---@param reason string Failure reason.
---@param message? string Human-readable message.
---@param fields? table Extra result fields.
---@return table result Structured failure.
function M.failed(reason, message, fields)
    return vim.tbl_extend("force", {
        ok = false,
        reason = reason,
        message = message or reason,
    }, fields or {})
end

---Normalize callback exceptions through the existing preview capability helper.
---@param project table Project state.
---@param operation string Preview operation name.
---@param err any Callback error.
---@return table result Structured callback failure.
function M.callback_error(project, operation, err)
    return capabilities.callback_error(project, operation, err)
end

---Build a failure for pending handles that cannot be observed.
---@param stage string Pending operation stage.
---@param err? any Subscription error.
---@return table result Structured failure.
function M.unobservable(stage, err)
    return M.failed(
        "finish_subscription_failed",
        ("Pending Typst preview %s could not be observed"):format(stage),
        { error = err }
    )
end

---Build the standard pending-open cancellation result.
---@param reason? string Cancellation reason.
---@return table result Structured cancellation.
function M.open_cancelled(reason)
    return {
        ok = true,
        opened = false,
        stopped = false,
        cancelled = true,
        superseded = true,
        reason = reason or "cancelled",
        message = "Typst preview open was cancelled before it became active",
    }
end

---Return a compact, snapshot-safe preview result.
---@param result any Backend result.
---@return table|nil compact Compact result.
function M.compact(result)
    if type(result) ~= "table" then
        return result ~= nil and { value = tostring(result) } or nil
    end
    return {
        ok = result.ok,
        reason = result.reason,
        message = result.message,
        opened = result.opened,
        stopped = result.stopped,
        cancelled = result.cancelled,
        cancel_pending = result.cancel_pending,
        superseded = result.superseded,
        stale = result.stale,
        pending = result.pending,
    }
end

---Return a stale preview-open result.
---@param result any Original backend result.
---@param reason? string Stale reason.
---@return table result Structured stale result.
function M.stale_open(result, reason)
    local out = type(result) == "table" and vim.deepcopy(result) or {}
    out.ok = false
    out.stale = true
    if reason == "reset" or reason == "project_changed" then
        out.reason = reason
        out.message = reason == "reset"
                and "Typst preview open result was ignored after typst.nvim reset"
            or "Typst preview open result was ignored after the project changed"
    else
        out.reason = out.reason or reason or "stale_preview_open"
        out.message = out.message
            or "Typst preview open result was ignored because a newer open replaced it"
    end
    return out
end

---Return whether a backend result is pending.
---@param result any Backend result.
---@return boolean pending True when pending.
function M.is_pending(result)
    return type(result) == "table" and result.pending == true
end

---Return whether an open result failed or declined.
---@param result any Backend result.
---@return boolean failed True when open failed.
function M.open_failed(result)
    return result == false
        or (
            type(result) == "table"
            and (result.ok == false or result.opened == false)
        )
end

---Return whether a stop result failed or declined.
---@param result any Backend result.
---@return boolean failed True when stop failed.
function M.stop_failed(result)
    if type(result) == "table" and result.stopped == true then
        return result.ok == false
            and result.warning ~= true
            and result.backend_stopped ~= true
    end
    return result == false
        or (
            type(result) == "table"
            and (result.ok == false or result.stopped == false)
        )
end

---Return whether a pending-open cancellation was confirmed.
---@param result any Cancellation result.
---@return boolean confirmed True when cancelled/stopped.
function M.cancel_confirmed(result)
    return type(result) == "table"
        and result.ok ~= false
        and result.stopped == true
end

return M
