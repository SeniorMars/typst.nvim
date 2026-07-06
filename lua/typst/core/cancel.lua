local M = {}

---Normalize a raw provider/operation cancel call result.
---@param called boolean Whether the cancel call itself completed.
---@param stopped any First return from cancel, or pcall error when `called` is false.
---@param result any Second return from cancel.
---@return boolean stopped True only when shutdown was confirmed.
---@return any result Normalized result or failure payload.
function M.normalize_call(called, stopped, result)
    if not called then
        return false, { error = stopped }
    end
    if type(stopped) == "table" and result == nil then
        result = stopped
        stopped = result.stopped
    end
    if stopped == nil and result == nil then
        return false,
            {
                reason = "cancel_no_result",
                message = "operation cancel returned no result",
            }
    end
    if stopped == false then
        return false, result
    end
    if type(result) == "table" then
        if result.pending == true then
            return false, result
        end
        if result.orphaned == true then
            return false, result
        end
        if result.stopped == false then
            return false, result
        end
        if result.ok == false and result.stopped ~= true then
            return false, result
        end
    end
    if stopped == true then
        return true, result or stopped
    end
    if type(result) == "table" and result.stopped == true then
        return true, result
    end
    return false, result or stopped
end

---Return whether a raw cancel call confirmed shutdown.
---@param called boolean
---@param stopped any
---@param result any
---@return boolean confirmed
function M.confirmed_call(called, stopped, result)
    if not called or stopped == false then
        return false
    end
    if type(stopped) == "table" and result == nil then
        result = stopped
        stopped = result.stopped
    end
    if stopped == nil and result == nil then
        return false
    end
    if type(result) == "table" then
        if result.pending == true then
            return false
        end
        if result.orphaned == true then
            return false
        end
        if result.stopped == false then
            return false
        end
        if result.ok == false and result.stopped ~= true then
            return false
        end
    end
    return stopped == true
        or (type(result) == "table" and result.stopped == true)
end

---Decide whether an unconfirmed cancel result deserves a receiver fallback.
---@param called boolean
---@param stopped any
---@param result any
---@return boolean
function M.should_try_fallback(called, stopped, result)
    if not called or (stopped == nil and result == nil) then
        return true
    end
    if type(stopped) == "table" and result == nil then
        result = stopped
        stopped = result.stopped
    end
    if stopped ~= false or type(result) ~= "table" then
        return false
    end
    return result.reason == "missing_reason"
        or result.reason == "wrong_receiver"
        or result.reason == "invalid_receiver"
end

local function result_payload(stopped, result)
    if type(result) == "table" then
        return result
    end
    if type(stopped) == "table" then
        return stopped
    end
    return nil
end

local function receiver_error(value)
    return type(value) == "table"
        and (
            value.reason == "missing_reason"
            or value.reason == "wrong_receiver"
            or value.reason == "invalid_receiver"
        )
end

local function call_cancel(handle, opts, style, callback)
    if style == "dot" then
        return pcall(handle.cancel, opts, callback)
    end
    return pcall(handle.cancel, handle, opts, callback)
end

---Infer the receiver convention for a provider/operation cancel method.
---@param handle any
---@return "dot"|"method" style
---@return boolean explicit True when the style came from handle metadata.
function M.style(handle)
    if type(handle) ~= "table" then
        return "dot", true
    end
    if
        handle.cancel_style == "dot"
        or handle._typst_cancel_style == "dot"
        or handle.deferred == true
    then
        return "dot", true
    end
    if
        handle.cancel_style == "colon"
        or handle.cancel_style == "method"
        or handle._typst_cancel_style == "colon"
        or handle.on_finish_style == "colon"
        or handle._typst_on_finish_style == "colon"
    then
        return "method", true
    end
    local ok, info = pcall(debug.getinfo, handle.cancel, "u")
    if ok and type(info) == "table" then
        if type(info.nparams) == "number" and info.nparams >= 2 then
            return "method", false
        end
        if info.isvararg ~= true and (info.nparams or 0) <= 1 then
            return "dot", false
        end
    end
    return "method", false
end

---Call a cancel handle with receiver fallback and normalized result semantics.
---@param handle table Provider/operation handle exposing `cancel`.
---@param opts? table Cancel options.
---@param callback? function Optional provider cancellation callback.
---@return boolean stopped True when shutdown was confirmed.
---@return any result Normalized cancellation result.
function M.call(handle, opts, callback)
    local first_style, explicit_style = M.style(handle)
    local called, stopped, result =
        call_cancel(handle, opts, first_style, callback)
    if
        not explicit_style and M.should_try_fallback(called, stopped, result)
    then
        local fallback_style = first_style == "dot" and "method" or "dot"
        local fallback_called, fallback_stopped, fallback_result =
            call_cancel(handle, opts, fallback_style, callback)
        if
            M.confirmed_call(fallback_called, fallback_stopped, fallback_result)
            or (
                receiver_error(result_payload(stopped, result))
                and fallback_called
                and not receiver_error(
                    result_payload(fallback_stopped, fallback_result)
                )
            )
        then
            called, stopped, result =
                fallback_called, fallback_stopped, fallback_result
        end
    end
    return M.normalize_call(called, stopped, result)
end

return M
