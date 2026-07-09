local async = require("typst.core.async")
local pending_handle = require("typst.core.pending")
local core_result = require("typst.core.result")

local M = {}

-- Temporary provider lifecycle bridge. Keep provider-owned pending handles here
-- until provider_adapter can move onto core.operation while deleting this older
-- timeout/cancel/public-handle path in the same change.
local uv = vim.uv or vim.loop
local schedule = async.schedule
local close_timer = async.close_timer

local proxy_result_fields = {
    "ok",
    "code",
    "signal",
    "pending",
    "stale",
    "reason",
    "message",
    "stopped",
    "forced",
    "cancelled",
    "timeout",
    "orphaned",
    "retained",
    "orphan_retained",
    "error",
    "provider",
    "method",
}

local function cancel_returned(value, cancel_opts)
    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then
        return false
    end
    if value_type == "table" and type(value.cancel) == "function" then
        return pending_handle.cancel(value, cancel_opts)
    end
    local handle = value_type == "table" and (value.handle or value) or value
    local handle_type = type(handle)
    if handle_type == "table" or handle_type == "userdata" then
        local ok, result = async.cancel_system(handle, {
            timeout_ms = cancel_opts and cancel_opts.timeout_ms or 0,
            kill_timeout_ms = cancel_opts and cancel_opts.kill_timeout_ms or 0,
        })
        return ok, result
    end
    return false
end

local function copy_proxy_result(proxy, result)
    if type(proxy) ~= "table" or type(result) ~= "table" then
        return
    end
    proxy.pending = false
    proxy.finished = true
    proxy.state = "finished"
    proxy.result = result
    for _, key in ipairs(proxy_result_fields) do
        if result[key] ~= nil then
            proxy[key] = result[key]
        end
    end
end

---Create a provider-backed lifecycle bridge using the shared pending contract.
---@param opts table Bridge options.
---@return table lifecycle Provider lifecycle bridge.
function M.new(opts)
    opts = opts or {}
    local timer = nil
    local cancel_timer = nil
    local returned_value = nil
    local returned_proxy = nil
    local completed_result = nil

    local function cancel_timeout_result(timeout_ms, cancel_result)
        if type(opts.cancel_timeout_result) == "function" then
            return opts.cancel_timeout_result(timeout_ms, cancel_result)
        end
        return core_result.failed(
            core_result.reason.cancel_unconfirmed,
            "Provider cancellation did not finish after timeout",
            {
                stopped = false,
                timeout = true,
                cancel_timeout_ms = timeout_ms,
                cancel_result = cancel_result,
            }
        )
    end

    local pending
    pending = pending_handle.new({
        kind = opts.kind,
        fields = vim.tbl_extend("force", {
            _typst_provider_lifecycle = true,
            _typst_handle_contract = "provider-pending",
            provider = opts.provider_name,
            method = opts.method,
            ok = false,
        }, opts.fields or {}),
        duplicate = opts.duplicate,
        complete = function(raw, handle, source)
            close_timer(timer)
            close_timer(cancel_timer)
            completed_result = opts.complete(raw, handle, source)
            copy_proxy_result(returned_proxy, completed_result)
            return completed_result
        end,
        cancel = function(_, cancel_opts, finish)
            local ok, result = cancel_returned(returned_value, cancel_opts)
            if pending.result ~= nil then
                return ok, result
            end
            if type(result) == "table" and result.pending == true then
                return ok, result
            end
            if returned_value == nil then
                return true,
                    finish(
                        opts.cancel_result(cancel_opts, true),
                        "cancel"
                    )
            end
            local terminal = opts.cancel_result(
                cancel_opts,
                ok ~= false,
                result
            )
            return ok, finish(terminal, "cancel")
        end,
    })

    local lifecycle = {
        pending = pending,
    }
    pending.on_result = function(self_or_callback, maybe_callback)
        return pending.on_finish(self_or_callback, maybe_callback)
    end

    function lifecycle.result()
        return completed_result
    end

    function lifecycle.finish(raw, source)
        return pending.finish(raw, source)
    end

    function lifecycle.callback(raw)
        return pending.finish(raw, "callback")
    end

    function lifecycle.set_returned(value)
        returned_value = value
        pending.handle = value
    end

    function lifecycle.start_timeout(timeout_ms)
        timeout_ms = tonumber(timeout_ms)
        if timer or not timeout_ms or timeout_ms <= 0 then
            return
        end

        timer = uv.new_timer()
        if not timer then
            return
        end
        timer:start(timeout_ms, 0, function()
            schedule(function()
                if pending.result ~= nil then
                    return
                end
                local cancel_ok, cancel_result = cancel_returned(
                    returned_value,
                    {
                        reason = opts.timeout_reason,
                        timeout_ms = 0,
                        kill_timeout_ms = 0,
                    }
                )
                if pending.result ~= nil then
                    return
                end
                if
                    type(cancel_result) == "table"
                    and cancel_result.pending == true
                then
                    close_timer(timer)
                    timer = nil
                    pending.state = "cancelling"
                    if type(returned_proxy) == "table" then
                        returned_proxy.state = "cancelling"
                    end
                    local cancel_timeout_ms = tonumber(
                        opts.cancel_timeout_ms or timeout_ms
                    ) or timeout_ms
                    if cancel_timeout_ms <= 0 then
                        pending.finish(
                            cancel_timeout_result(cancel_timeout_ms, cancel_result),
                            "cancel_timeout"
                        )
                        return
                    end
                    cancel_timer = uv.new_timer()
                    if not cancel_timer then
                        pending.finish(
                            cancel_timeout_result(cancel_timeout_ms, cancel_result),
                            "cancel_timeout"
                        )
                        return
                    end
                    cancel_timer:start(cancel_timeout_ms, 0, function()
                        schedule(function()
                            if pending.result ~= nil then
                                return
                            end
                            pending.finish(
                                cancel_timeout_result(cancel_timeout_ms, cancel_result),
                                "cancel_timeout"
                            )
                        end)
                    end)
                    return
                end
                pending.finish(
                    opts.timeout_result(timeout_ms, cancel_ok, cancel_result),
                    "timeout"
                )
            end)
        end)
    end

    function lifecycle.proxy_for(value)
        if type(value) ~= "table" then
            return value
        end

        -- Return a proxy rather than mutating provider handles directly. Some
        -- providers reuse their handle table internally, while typst.nvim needs
        -- normalized cancel/result fields to expose to callers.
        local proxy = {}
        for key, child in pairs(value) do
            proxy[key] = child
        end
        proxy._typst_lifecycle_handle = true
        proxy._typst_pending_handle = true
        proxy._typst_provider_lifecycle = true
        proxy._typst_handle_contract = "provider-pending"
        proxy.provider = proxy.provider or opts.provider_name
        proxy.method = proxy.method or opts.method
        proxy.kind = proxy.kind or opts.kind
        proxy.handle = proxy.handle or value
        proxy.pending = true
        proxy.finished = false
        proxy.state = "pending"
        proxy.on_finish_style = "colon"
        proxy._typst_on_finish_style = "colon"
        local function subscribe(self_or_callback, maybe_callback)
            local callback = maybe_callback
            if self_or_callback ~= proxy then
                callback = self_or_callback
            end
            if type(callback) ~= "function" then
                return proxy
            end
            pending:on_finish(function(result)
                callback(result, proxy)
            end)
            return proxy
        end
        proxy.on_finish = subscribe
        proxy.on_result = subscribe
        proxy.cancel = function(self_or_opts, maybe_opts)
            local cancel_opts = maybe_opts
            if self_or_opts ~= proxy then
                cancel_opts = self_or_opts
            end

            if pending.result ~= nil then
                return true, pending.result
            end

            local ok, result = cancel_returned(value, cancel_opts)
            if pending.result ~= nil then
                return ok ~= false, result
            end
            if type(result) == "table" and result.pending == true then
                return ok ~= false, result
            end

            local terminal = opts.cancel_result(
                cancel_opts,
                ok ~= false,
                result
            )
            return ok ~= false, pending.finish(terminal, "cancel")
        end

        returned_proxy = proxy
        return proxy
    end

    return lifecycle
end

return M
