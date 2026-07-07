local M = {}

local function symbol(endpoint)
    if type(endpoint) ~= "table" then
        return "runtime.unknown"
    end
    return endpoint.operation
        or ("%s.%s"):format(endpoint.namespace or "?", endpoint.name or "?")
end

local function notify_level(policy, fallback)
    local level = policy and policy.notify_level
    if level == "error" then
        return vim.log.levels.ERROR
    end
    if level == "warn" then
        return vim.log.levels.WARN
    end
    if level == "info" then
        return vim.log.levels.INFO
    end
    if type(level) == "number" then
        return level
    end
    return fallback
end

function M.error_payload(endpoint, reason, message, fields)
    return vim.tbl_extend("force", {
        ok = false,
        reason = reason or "runtime_error",
        message = message or reason or "Typst runtime API error",
        operation = symbol(endpoint),
        namespace = endpoint and endpoint.namespace or nil,
        method = endpoint and endpoint.name or nil,
    }, fields or {})
end

function M.route_resolution_error(endpoint, err, callback, notify, opts)
    local result_policy = endpoint.result or {}
    opts = opts or {}
    local payload = M.error_payload(
        endpoint,
        err and err.reason or "no_project",
        err and err.message or "No Typst project is attached",
        err
    )
    if type(result_policy.failure_fields) == "table" then
        payload = vim.tbl_extend("force", payload, result_policy.failure_fields)
    end

    local callback_called = false
    if
        result_policy.callback_on_resolution_error == true
        and type(callback) == "function"
    then
        pcall(callback, payload)
        callback_called = true
    elseif
        payload.reason == "resolution_pending"
        and type(callback) == "function"
    then
        pcall(callback, payload)
        callback_called = true
    end

    if
        result_policy.notify_on_resolution_error
        and opts.notify ~= false
        and type(notify) == "function"
    then
        local by_reason = result_policy.notify_levels_by_reason or {}
        notify(
            payload.message,
            notify_level({
                notify_level = by_reason[payload.reason]
                    or result_policy.notify_level,
            }, vim.log.levels.WARN)
        )
    end

    if
        result_policy.resolution_error == "payload"
        or result_policy.resolution_error == "status_payload"
        or (payload.reason == "resolution_pending" and callback_called)
    then
        return payload
    end

    return nil, payload
end

function M.handler_missing(endpoint)
    return M.error_payload(
        endpoint,
        "handler_missing",
        ("Runtime API handler is missing for %s"):format(symbol(endpoint))
    )
end

function M.invalid_handler_call(endpoint)
    return M.error_payload(
        endpoint,
        "invalid_handler_call",
        ("Runtime API handler call style is invalid for %s"):format(
            symbol(endpoint)
        )
    )
end

function M.route_handler_exception(endpoint, err, callback, notify)
    local result_policy = endpoint.result or {}
    local payload =
        M.error_payload(endpoint, "handler_exception", tostring(err), {
            error = err,
        })

    local ok_log, log = pcall(require, "typst.core.log")
    if ok_log and type(log) == "table" and type(log.add) == "function" then
        pcall(log.add, "error", "runtime API handler failed", {
            operation = symbol(endpoint),
            error = err,
        })
    end

    if result_policy.handler_exception == "throw" then
        error(err, 0)
    end

    if type(callback) == "function" then
        pcall(callback, payload)
    end
    if result_policy.notify_on_handler_error and type(notify) == "function" then
        notify(
            payload.message,
            notify_level(result_policy, vim.log.levels.ERROR)
        )
    end

    return payload
end

return M
