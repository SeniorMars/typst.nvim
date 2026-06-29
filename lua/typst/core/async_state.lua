local M = {}

function M.traceback(err)
    if debug and debug.traceback then
        return debug.traceback(err, 2)
    end
    return err
end

function M.protect(fn)
    return xpcall(fn, M.traceback)
end

function M.clear_pending(state, fields)
    if type(state) ~= "table" then
        return
    end

    state.pending = false
    for _, field in ipairs(fields or {}) do
        state[field] = nil
    end
end

function M.fail_pending(state, err, fields, opts)
    opts = opts or {}
    M.clear_pending(state, fields)
    state.error = {
        ok = false,
        reason = opts.reason or "request_failed",
        message = tostring(err),
        error = tostring(err),
    }
end

function M.start_pending(state, fields, start, opts)
    local ok, result = M.protect(start)
    if not ok then
        M.fail_pending(state, result, fields, opts)
    end
    return ok, result
end

return M
