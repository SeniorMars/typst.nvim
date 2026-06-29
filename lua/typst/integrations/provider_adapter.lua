local async = require("typst.core.async")
local async_state = require("typst.core.async_state")
local log = require("typst.core.log")
local tables = require("typst.core.tables")

local M = {}

local uv = vim.uv or vim.loop
local unpack = tables.unpack

---@class typst.ProviderResult
---@field ok boolean?
---@field reason string?
---@field provider string?
---@field error string?
---@field message string?
---@field client string?
---@field method string?
---@field pending boolean?
---@field stopped boolean?
---@field forced boolean?
---@field orphaned boolean?

---@class typst.ProviderCancelHandle
---@field ok boolean?
---@field reason string?
---@field provider string?
---@field error string?
---@field message string?
---@field pending boolean?
---@field handle any
---@field cancel? fun(self_or_opts: typst.ProviderCancelHandle|table?, opts?:table): boolean, typst.ProviderResult|nil

-- Adapter for user/provider callbacks.
--
-- Providers in typst.nvim may return synchronously, call a callback later,
-- return a pending handle, or expose cancellation. Normalize those shapes here
-- so compiler, viewer, lint, export, and index integrations can share one
-- timeout/cancel/duplicate-result contract.
local schedule = async.schedule
local close_timer = async.close_timer

local function provider_name(provider, fallback)
    if type(provider) == "table" and type(provider.name) == "string" then
        return provider.name
    end
    return fallback or (type(provider) == "function" and "callback" or "table")
end

local function method_names(method)
    if type(method) == "table" then
        return method
    end
    if type(method) == "string" and method ~= "" then
        return { method }
    end
    return {}
end

local function select_method(provider, method)
    if type(provider) == "function" then
        return provider, "callback"
    end

    if type(provider) ~= "table" then
        return nil, nil
    end

    for _, name in ipairs(method_names(method)) do
        if type(provider[name]) == "function" then
            return provider[name], name
        end
    end

    return nil, nil
end

--- Classify whether a provider return value is already a terminal result.
---
--- Anything outside this shape is treated as a handle unless a caller supplied
--- a normalizer, which lets providers return custom process objects without
--- typst.nvim misclassifying them as completed work.
---@param value any Provider return value to classify.
---@return boolean result_like True when `value` should be treated as a completed provider result.
function M.result_like(value)
    if type(value) == "string" then
        return true
    end
    if type(value) ~= "table" then
        return false
    end

    return value.ok ~= nil
        or value.code ~= nil
        or value.reason ~= nil
        or value.message ~= nil
        or value.stopped ~= nil
        or value.forced ~= nil
        or value.orphaned ~= nil
        or value.output ~= nil
        or value.text ~= nil
        or value.path ~= nil
        or value.artifacts ~= nil
        or value.outputs ~= nil
        or value.by_buffer ~= nil
        or value.diagnostics ~= nil
end

local function explicit_result_like(value)
    return type(value) == "table"
        and (
            value.ok ~= nil
            or value.code ~= nil
            or value.reason ~= nil
            or value.message ~= nil
            or value.stopped ~= nil
            or value.forced ~= nil
            or value.orphaned ~= nil
        )
end

local function invalid_result(kind, name, message)
    return {
        ok = false,
        reason = "invalid_result",
        provider = name,
        message = message
            or ("%s provider returned no result"):format(kind or "tool"),
    }
end

local function provider_error(kind, name, err)
    return {
        ok = false,
        reason = "provider_error",
        provider = name,
        message = tostring(err),
        error = tostring(err),
    }
end

local function timeout_result(kind, name, timeout_ms)
    return {
        ok = false,
        reason = "timeout",
        provider = name,
        message = ("%s provider timed out after %dms"):format(
            kind or "tool",
            timeout_ms or 0
        ),
    }
end

local function normalize_result(control, raw, name)
    local normalize = control.normalize
    local result = raw

    if type(normalize) == "function" then
        local ok, normalized = async_state.protect(function()
            return normalize(raw, name)
        end)
        if not ok then
            return provider_error(control.kind, name, normalized)
        end
        result = normalized
    end

    if result == nil then
        return invalid_result(
            control.kind,
            name,
            control.invalid_result_message
        )
    end

    return result
end

local function protected_callback(control, result, context)
    if type(control.on_result) ~= "function" then
        return
    end

    local ok, err = async_state.protect(function()
        control.on_result(result, context)
    end)
    if not ok then
        log.add("warn", "provider result callback failed", {
            kind = control.kind,
            provider = control.provider_name,
            error = err,
        })
    end
end

local function insert_callback(args, callback, position)
    local copied = {}
    for index, value in ipairs(args or {}) do
        copied[index] = value
    end
    args = copied
    position = tonumber(position) or (#args + 1)
    if position < 1 then
        position = #args + 1
    end
    table.insert(args, math.min(position, #args + 1), callback)
    return args
end

local function cancel_returned(value, cancel_opts)
    if type(value) ~= "table" then
        return false
    end
    if type(value.cancel) == "function" then
        local ok, stopped, result = pcall(value.cancel, value, cancel_opts)
        if ok then
            return stopped ~= false, result
        end
        return false, stopped
    end
    local handle = value.handle or value
    if type(handle) == "table" then
        local ok, result = async.cancel_system(handle, {
            timeout_ms = cancel_opts and cancel_opts.timeout_ms or 0,
            kill_timeout_ms = cancel_opts and cancel_opts.kill_timeout_ms or 0,
        })
        return ok, result
    end
    return false
end

--- Invoke a provider method and normalize synchronous, async, and cancelable returns.
---@param provider table|fun(...):any Provider table or callback-style provider.
---@param method string|string[] Provider method name or fallback method names.
---@param context? table Project or request context passed to provider callbacks.
---@param opts? table Provider-specific options passed through to the invocation.
---@param control? table Adapter controls such as timeout, callback position, and result normalizer.
---@return typst.ProviderCancelHandle|typst.ProviderResult|table|nil result Provider result, pending handle, or nil when handle-only invocation cannot start.
function M.invoke(provider, method, context, opts, control)
    opts = opts or {}
    control = control or {}

    local kind = control.kind or "provider"
    local name = control.provider_name or provider_name(provider)
    control.provider_name = name

    local fn, selected_method = select_method(provider, method)
    if not fn then
        local result = invalid_result(
            kind,
            name,
            ("%s provider does not expose %s"):format(
                kind,
                table.concat(method_names(method), ", ")
            )
        )
        if control.return_mode == "handle" then
            protected_callback(control, result, context)
            return nil
        end
        return result
    end

    local completed = false
    local timer = nil
    local normalized_result = nil
    local returned_value = nil
    local returned_proxy = nil
    local pending = {
        ok = false,
        pending = true,
        provider = name,
        kind = kind,
        method = selected_method,
    }

    local function finish(raw, source)
        if completed then
            -- Late provider callbacks are common after timeouts or manual
            -- cancellation. The first terminal result wins to keep state
            -- transitions single-shot.
            log.add("warn", "ignored duplicate provider result", {
                kind = kind,
                provider = name,
                source = source,
            })
            return normalized_result
        end

        completed = true
        close_timer(timer)
        pending.pending = false
        normalized_result = normalize_result(control, raw, name)
        if
            type(returned_proxy) == "table"
            and type(normalized_result) == "table"
        then
            returned_proxy.pending = false
            for _, key in ipairs({
                "ok",
                "reason",
                "message",
                "stopped",
                "forced",
                "orphaned",
                "error",
            }) do
                if normalized_result[key] ~= nil then
                    returned_proxy[key] = normalized_result[key]
                end
            end
        end
        protected_callback(control, normalized_result, context)
        return normalized_result
    end

    local function provider_callback(raw)
        return finish(raw, "callback")
    end

    -- Start timeouts only after provider invocation so a provider that calls back
    -- synchronously is returned as a result, not briefly exposed as pending.
    local function start_timeout()
        local timeout_ms = tonumber(control.timeout_ms)
        if timer or not timeout_ms or timeout_ms <= 0 then
            return
        end

        timer = uv.new_timer()
        timer:start(timeout_ms, 0, function()
            schedule(function()
                if completed then
                    return
                end
                -- Prefer asking the provider-owned handle to cancel before
                -- reporting timeout. If it still calls back later, finish() will
                -- drop the duplicate result.
                cancel_returned(returned_value, {
                    reason = "timeout",
                    timeout_ms = 0,
                    kill_timeout_ms = 0,
                })
                if completed then
                    return
                end
                finish(timeout_result(kind, name, timeout_ms), "timeout")
            end)
        end)
    end

    local args = control.args or { context, opts }
    -- Callback position is part of each provider contract; command-like APIs
    -- and callback-style APIs do not all put it at the end.
    args = insert_callback(args, provider_callback, control.callback_position)

    local ok, returned = async_state.protect(function()
        return fn(unpack(args))
    end)

    if not ok then
        local result = finish(provider_error(kind, name, returned), "error")
        if control.return_mode == "handle" then
            return nil
        end
        return result
    end

    returned_value = returned
    pending.handle = returned
    pending.cancel = function(cancel_opts)
        local ok, result = cancel_returned(returned_value, cancel_opts)
        if completed then
            return ok, result
        end
        if type(result) == "table" and result.pending == true then
            return ok, result
        end
        if returned_value == nil then
            return true,
                finish({
                    ok = false,
                    reason = (cancel_opts and cancel_opts.reason)
                        or "cancelled",
                    stopped = true,
                    message = ("%s provider invocation was cancelled"):format(
                        kind
                    ),
                }, "cancel")
        end
        local terminal = type(result) == "table"
                and M.result_like(result)
                and result
            or {
                ok = false,
                reason = (cancel_opts and cancel_opts.reason) or "cancelled",
                stopped = ok ~= false,
                message = ("%s provider invocation was cancelled"):format(kind),
            }
        return ok, finish(terminal, "cancel")
    end

    local function pending_proxy_for(value)
        if type(value) ~= "table" then
            return value
        end

        -- Return a proxy rather than mutating provider handles directly. Some
        -- providers reuse their handle table internally, while typst.nvim needs
        -- normalized cancel/result fields to expose to callers.
        local original_cancel = value.cancel
        local proxy = {}
        for key, child in pairs(value) do
            proxy[key] = child
        end
        proxy.handle = proxy.handle or value
        proxy.cancel = function(self_or_opts, maybe_opts)
            local cancel_opts = maybe_opts
            if self_or_opts ~= proxy then
                cancel_opts = self_or_opts
            end

            local ok, result
            if type(original_cancel) == "function" then
                local called
                called, ok, result = pcall(original_cancel, value, cancel_opts)
                if not called then
                    return false,
                        finish(provider_error(kind, name, ok), "cancel")
                end
            else
                ok, result = cancel_returned(value, cancel_opts)
            end

            if completed then
                return ok ~= false, result
            end
            if type(result) == "table" and result.pending == true then
                return ok ~= false, result
            end

            local terminal = type(result) == "table"
                    and M.result_like(result)
                    and result
                or {
                    ok = false,
                    reason = (cancel_opts and cancel_opts.reason)
                        or "cancelled",
                    stopped = ok ~= false,
                    message = ("%s provider invocation was cancelled"):format(
                        kind
                    ),
                }
            return ok ~= false, finish(terminal, "cancel")
        end
        returned_proxy = proxy
        return proxy
    end

    local timeout_configured = tonumber(control.timeout_ms)
        and tonumber(control.timeout_ms) > 0
    local async_expected = control.async ~= false
        and (type(control.on_result) == "function" or timeout_configured)
    local returned_pending = type(returned) == "table"
        and returned.pending == true
    local returned_handle = type(control.is_handle) == "function"
        and control.is_handle(returned)
    local handle_mode = control.return_mode == "handle"
    local returned_result = returned ~= nil
        and not returned_pending
        and not returned_handle
        and (
            control.accept_table_result == true
            or (handle_mode and explicit_result_like(returned))
            or (not handle_mode and M.result_like(returned))
            or (not handle_mode and type(control.normalize) == "function")
        )

    if
        returned ~= nil
        and control.return_mode == "handle"
        and returned_result
        and not completed
        and not control.prefer_handle
    then
        finish(returned, "return")
        return returned
    end

    if returned ~= nil and control.return_mode == "handle" then
        if not completed and async_expected then
            start_timeout()
        end
        if control.expect_handle and not completed then
            local handle_type = type(returned)
            if handle_type ~= "table" and handle_type ~= "userdata" then
                finish(
                    invalid_result(
                        kind,
                        name,
                        ("%s provider returned an invalid handle"):format(kind)
                    ),
                    "handle_validation"
                )
            end
        end
        if returned_pending then
            return pending_proxy_for(returned)
        end
        return returned
    end

    if completed then
        return normalized_result
    end

    if returned ~= nil and returned_result then
        return finish(returned, "return")
    end

    if returned_pending or returned_handle then
        if async_expected then
            start_timeout()
        end
        if returned_pending and type(returned) == "table" then
            return pending_proxy_for(returned)
        end
        return returned
    end

    if not async_expected then
        if control.allow_nil_result then
            return finish(nil, "missing_result")
        end
        return finish(
            invalid_result(kind, name, control.invalid_result_message),
            "missing_result"
        )
    end

    start_timeout()

    if returned ~= nil then
        return returned
    end
    return pending
end

return M
