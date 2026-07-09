local log = require("typst.core.log")
local core_result = require("typst.core.result")

local M = {}

local function protected_call(callback, ...)
    local ok, err = pcall(callback, ...)
    if not ok then
        log.add("warn", "pending callback failed", {
            error = tostring(err),
        })
    end
end

local function default_cancel_result(opts, stopped)
    return {
        ok = false,
        reason = opts and opts.reason or core_result.reason.cancelled,
        stopped = stopped ~= false,
    }
end

local function cancel_unconfirmed_result(opts)
    return {
        ok = false,
        reason = core_result.reason.cancel_unconfirmed,
        message = "Pending handle cancel did not confirm shutdown",
        requested_reason = opts and opts.reason or nil,
        stopped = false,
    }
end

local function normalize_cancel_return(stopped, result, opts)
    if type(stopped) == "table" and result == nil then
        result = stopped
        stopped = result.stopped
    end

    if type(result) == "table" then
        if result.stopped == true then
            return true, result
        end
        if result.pending == true then
            return false, result
        end
        if result.stopped == false or result.ok == false or result.reason then
            if result.stopped == nil then
                result.stopped = false
            end
            return false, result
        end
    end

    if stopped == true then
        return true, result or default_cancel_result(opts, true)
    end
    if stopped == false then
        return false, result or default_cancel_result(opts, false)
    end

    return false, result or cancel_unconfirmed_result(opts)
end

local function copy_fields(target, fields)
    for key, value in pairs(fields or {}) do
        target[key] = value
    end
end

local function handle_state(source)
    if type(source) ~= "table" then
        return nil
    end
    return {
        id = source.id,
        kind = source.kind,
        owner = source.owner,
        project_key = source.project_key,
        pending = source.pending == true,
        finished = source.finished == true or source.state == "finished",
        state = source.state,
        result = source.result,
    }
end

local function cancel_style(source, opts)
    local style = opts and opts.style or nil
    if style == nil and type(source) == "table" then
        style = source.cancel_style or source._typst_cancel_style
    end
    if style == "method" then
        style = "colon"
    end
    if style == nil then
        if
            type(source) == "table"
            and (source.on_finish_style or source._typst_on_finish_style)
                == "dot"
        then
            return nil, "dot_cancel_requires_explicit_style"
        end
        return "colon"
    end
    if style ~= "colon" and style ~= "dot" then
        return nil, "unsupported_cancel_style"
    end
    return style
end

local function call_cancel(source, opts, call_opts)
    if type(source) ~= "table" then
        return true, default_cancel_result(opts, true)
    end
    if type(source.cancel) ~= "function" then
        if source.pending == true or type(source.on_finish) == "function" then
            return false,
                {
                    ok = false,
                    reason = "cancel_unavailable",
                    message = "Pending handle does not expose cancel",
                    stopped = false,
                }
        end
        return true, default_cancel_result(opts, true)
    end

    local style, style_error = cancel_style(source, call_opts)
    if not style then
        return false,
            {
                ok = false,
                reason = style_error,
                message = "Pending handle cancellation needs an explicit cancel_style",
                stopped = false,
            }
    end

    local ok, stopped, result
    if style == "dot" then
        ok, stopped, result =
            pcall(source.cancel, opts, call_opts and call_opts.callback)
    else
        ok, stopped, result =
            pcall(source.cancel, source, opts, call_opts and call_opts.callback)
    end
    if ok then
        return normalize_cancel_return(stopped, result, opts)
    end

    return false,
        {
            ok = false,
            reason = "cancel_failed",
            message = tostring(stopped),
            stopped = false,
        }
end

---Cancel another pending handle using an explicit cancel calling convention.
---@param source any Pending source handle.
---@param opts? table Cancellation options passed to the provider handle.
---@param call_opts? {style?:"colon"|"dot"|"method", callback?:function} Calling
---convention.
---@return boolean stopped False when cancellation failed or was unconfirmed.
---@return any result Provider cancellation result or normalized failure.
function M.cancel(source, opts, call_opts)
    return call_cancel(source, opts, call_opts)
end

---Create a single-shot pending handle with shared finish/on_finish/cancel rules.
---@param opts? table
---@return table handle
function M.new(opts)
    opts = opts or {}
    local callbacks = {}
    local finished = false
    local source = opts.handle
    local complete = type(opts.complete) == "function" and opts.complete
        or function(raw)
            return raw
        end

    local handle = {
        _typst_lifecycle_handle = true,
        _typst_pending_handle = true,
        _typst_handle_contract = "pending",
        pending = true,
        finished = false,
        state = "pending",
        id = opts.id,
        kind = opts.kind,
        owner = opts.owner,
        project_key = opts.project_key,
        handle = source,
        on_finish_style = opts.on_finish_style or "colon",
        _typst_on_finish_style = opts.on_finish_style or "colon",
        _typst_cancel_style = opts.cancel_style,
    }

    if opts.copy_handle_fields and type(source) == "table" then
        copy_fields(handle, source)
        handle.handle = handle.handle or source
        handle.pending = true
    end
    copy_fields(handle, opts.fields)

    function handle.finish(self_or_raw, maybe_raw, maybe_source)
        local raw = maybe_raw
        local source_name = maybe_source
        if self_or_raw ~= handle then
            raw = self_or_raw
            source_name = maybe_raw
        end

        if finished then
            if type(opts.duplicate) == "function" then
                protected_call(opts.duplicate, handle, raw, source_name)
            end
            return handle.result
        end

        finished = true
        handle.finished = true
        handle.pending = false
        handle.state = "finished"
        local ok, result = pcall(complete, raw, handle, source_name)
        if not ok then
            result = {
                ok = false,
                reason = core_result.reason.pending_complete_failed,
                message = tostring(result),
                error = tostring(result),
            }
        end

        handle.result = result
        if opts.copy_result_fields == true and type(result) == "table" then
            copy_fields(handle, result)
        end

        for _, callback in ipairs(callbacks) do
            protected_call(callback, result, handle)
        end
        callbacks = {}
        return result
    end

    function handle.on_finish(self_or_callback, maybe_callback)
        local callback = maybe_callback
        if self_or_callback ~= handle then
            callback = self_or_callback
        end
        if type(callback) ~= "function" then
            return handle
        end
        if finished then
            protected_call(callback, handle.result, handle)
        else
            callbacks[#callbacks + 1] = callback
        end
        return handle
    end

    function handle.cancel(self_or_opts, maybe_opts)
        local cancel_opts = maybe_opts
        if self_or_opts ~= handle then
            cancel_opts = self_or_opts
        end

        if finished then
            return true,
                handle.result or core_result.idle({
                    already_finished = true,
                })
        end

        local stopped, result
        handle.state = "cancelling"
        if type(opts.cancel) == "function" then
            local ok, cancel_stopped, cancel_result =
                pcall(opts.cancel, handle, cancel_opts, handle.finish)
            if ok then
                stopped, result = normalize_cancel_return(
                    cancel_stopped,
                    cancel_result,
                    cancel_opts
                )
            else
                stopped, result =
                    false, {
                        ok = false,
                        reason = core_result.reason.cancel_failed,
                        message = tostring(cancel_stopped),
                        stopped = false,
                    }
            end
        else
            stopped, result = call_cancel(source, cancel_opts, {
                style = opts.cancel_style,
            })
        end

        if finished then
            return stopped ~= false, result or handle.result
        end

        if type(result) == "table" and result.pending == true then
            handle.state = "cancelling"
            return stopped ~= false, result
        end

        if result == nil then
            result = default_cancel_result(cancel_opts, stopped)
        end

        return stopped ~= false, handle.finish(result, "cancel")
    end

    return handle
end

---Return whether a value exposes typst.nvim's pending/operation lifecycle shape.
---@param source any
---@return boolean
function M.is_handle(source)
    return type(source) == "table"
        and (
            source._typst_lifecycle_handle == true
            or source._typst_pending_handle == true
            or source._typst_operation_handle == true
            or source.pending == true
            or type(source.on_finish) == "function"
            or type(source.on_result) == "function"
        )
end

---Return whether a lifecycle handle is terminal.
---@param source any
---@return boolean
function M.finished(source)
    return type(source) == "table"
        and (
            source.finished == true
            or source.state == "finished"
            or source.pending == false and source.result ~= nil
        )
end

---Return the terminal result for a lifecycle handle when available.
---@param source any
---@return any result
function M.result(source)
    if type(source) == "table" then
        return source.result
    end
    return nil
end

---Return a compact lifecycle snapshot for pending and operation handles.
---@param source any
---@return table|nil state
function M.state(source)
    return handle_state(source)
end

---Subscribe to another handle using an explicit on_finish calling convention.
---@param source any Pending source handle.
---@param callback function Callback to run when `source` finishes.
---@param opts? {style?:"colon"|"dot"} Subscription options.
---@return boolean ok
---@return any result_or_error
function M.subscribe(source, callback, opts)
    if type(source) ~= "table" or type(callback) ~= "function" then
        return false, "missing pending source or callback"
    end
    if type(source.on_finish) ~= "function" then
        return false, "pending source has no on_finish"
    end

    local style = opts and opts.style or "colon"
    if style ~= "colon" and style ~= "dot" then
        return false, ("unsupported on_finish style %s"):format(tostring(style))
    end

    local ok, result
    if style == "dot" then
        ok, result = pcall(function()
            return source.on_finish(callback)
        end)
    else
        ok, result = pcall(function()
            return source:on_finish(callback)
        end)
    end

    if ok then
        return true, result
    end
    return false, result
end

---Subscribe with the converged result callback shape `(result, handle)`.
---@param source any Pending or operation-like handle.
---@param callback fun(result:any, handle:any)
---@param opts? {style?:"colon"|"dot"}
---@return boolean ok
---@return any result_or_error
function M.subscribe_result(source, callback, opts)
    if type(callback) ~= "function" then
        return false, "missing pending callback"
    end
    if type(source) ~= "table" then
        return false, "missing pending source"
    end

    if type(source.on_result) == "function" then
        local ok, result = pcall(function()
            return source:on_result(callback)
        end)
        if ok then
            return true, result
        end
        return false, result
    end

    return M.subscribe(source, function(result)
        callback(result, source)
    end, opts)
end

---Subscribe to a handle that may expose explicit or legacy receiver style.
---@param source any Pending source handle.
---@param callback function Callback to run when `source` finishes.
---@return boolean ok
---@return any result_or_error
function M.subscribe_compatible(source, callback)
    if type(source) == "table" and type(source.on_result) == "function" then
        return M.subscribe_result(source, callback)
    end
    local style = type(source) == "table"
            and (source.on_finish_style or source._typst_on_finish_style)
        or nil
    if style then
        return M.subscribe(source, callback, { style = style })
    end

    local ok, result = M.subscribe(source, callback, { style = "dot" })
    if ok then
        return ok, result
    end
    return M.subscribe(source, callback)
end

return M
