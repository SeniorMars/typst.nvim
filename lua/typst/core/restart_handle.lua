local M = {}

local function delegate_cancel(handle, opts, callback)
    if type(handle) ~= "table" then
        return false, { reason = "not_cancellable" }
    end

    if type(handle.cancel) == "function" then
        local ok, stopped, result = pcall(handle.cancel, handle, opts, callback)
        if ok then
            return stopped, result
        end

        ok, stopped, result = pcall(handle.cancel, opts, callback)
        if ok then
            return stopped, result
        end
        return false, { reason = "cancel_failed", error = stopped }
    end

    if type(handle.stop) == "function" then
        local ok, stopped, result = pcall(handle.stop, handle, opts, callback)
        if ok then
            return stopped, result
        end
        return false, { reason = "cancel_failed", error = stopped }
    end

    return false, { reason = "not_cancellable" }
end

function M.new(opts)
    opts = opts or {}
    local callbacks = {}
    local handle = {
        pending = true,
        stopping = true,
        cancel_requested = false,
        stop_handle = nil,
        next_handle = nil,
        result = nil,
        restart = true,
        kind = opts.kind,
        on_finish_style = "colon",
    }

    function handle:set_stop_handle(stop_handle)
        self.stop_handle = stop_handle
        if not self.handle then
            self.handle = stop_handle
        end
        return self
    end

    function handle:set_next_handle(next_handle)
        self.next_handle = next_handle
        self.handle = next_handle
        self.stopping = false
        return self
    end

    function handle:finish(result)
        if self.result ~= nil then
            return self.result
        end

        self.pending = false
        self.stopping = false
        self.result = result
        for _, callback in ipairs(callbacks) do
            pcall(callback, result, self)
        end
        callbacks = {}
        return result
    end

    function handle:on_finish(callback)
        if type(callback) ~= "function" then
            return self
        end
        if self.result ~= nil then
            pcall(callback, self.result, self)
        else
            callbacks[#callbacks + 1] = callback
        end
        return self
    end

    function handle:snapshot()
        return {
            pending = self.pending,
            stopping = self.stopping,
            restart = true,
            kind = self.kind,
            stop_handle = self.stop_handle,
            next_handle = self.next_handle,
            result = self.result,
            cancel_requested = self.cancel_requested,
        }
    end

    function handle.cancel(self_or_opts, maybe_opts, maybe_callback)
        local self = handle
        local opts = self_or_opts
        local callback = maybe_opts
        if self_or_opts == handle then
            opts = maybe_opts
            callback = maybe_callback
        end

        if self.result ~= nil then
            return false,
                {
                    ok = false,
                    reason = "finished",
                    message = ("%s restart has already finished"):format(
                        self.kind or "operation"
                    ),
                }
        end

        local target = self.next_handle or self.stop_handle
        self.cancel_requested = true
        if target then
            local stopped, result = delegate_cancel(target, opts, callback)
            if
                self.result == nil
                and not (type(result) == "table" and result.pending == true)
            then
                self:finish(type(result) == "table" and result or {
                    ok = false,
                    reason = opts and opts.reason or "cancelled",
                    stopped = stopped ~= false,
                })
            end
            return stopped, result
        end

        local result = {
            ok = false,
            stopped = true,
            reason = opts and opts.reason or "cancelled",
        }
        if type(callback) == "function" then
            callback(true, result)
        end
        self:finish(result)
        return true, result
    end

    return handle
end

return M
