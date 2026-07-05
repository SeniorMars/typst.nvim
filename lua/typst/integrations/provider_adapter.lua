local async = require("typst.core.async")
local async_state = require("typst.core.async_state")
local log = require("typst.core.log")
local pending_handle = require("typst.core.pending")
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
--- a normalizer or explicitly opted into table result shapes. This prevents
--- handle-like provider tables from being misclassified only because they
--- contain fields such as `path` or `diagnostics`.
---@param value any Provider return value to classify.
---@return boolean result_like True when `value` should be treated as a completed provider result.
function M.result_like(value)
    if type(value) == "string" then
        return true
    end
    if type(value) ~= "table" then
        return false
    end
    if value.pending == true then
        return false
    end

    return value.ok ~= nil
        or value.code ~= nil
        or value.reason ~= nil
        or value.message ~= nil
        or value.stopped ~= nil
        or value.forced ~= nil
        or value.orphaned ~= nil
        or value.idle ~= nil
end

local function explicit_terminal_result(value)
    return type(value) == "table"
        and value.pending ~= true
        and (
            value.ok ~= nil
            or value.code ~= nil
            or value.reason ~= nil
            or value.message ~= nil
            or value.stopped ~= nil
            or value.forced ~= nil
            or value.orphaned ~= nil
            or value.idle ~= nil
        )
end

local function allowed_result_field(control, value)
    if type(value) ~= "table" then
        return false
    end
    local fields = control.result_fields
    if type(fields) ~= "table" then
        return false
    end
    for key, enabled in pairs(fields) do
        if enabled and value[key] ~= nil then
            return true
        end
    end
    for _, key in ipairs(fields) do
        if value[key] ~= nil then
            return true
        end
    end
    return false
end

local ambiguous_structural_fields = {
    artifacts = true,
    by_buffer = true,
    diagnostics = true,
    files = true,
    opened = true,
    output = true,
    outputs = true,
    path = true,
    report = true,
    text = true,
    value = true,
}

local function has_cancel_api(value)
    return type(value) == "table"
        and (
            type(value.cancel) == "function"
            or type(value.stop) == "function"
            or type(value.kill) == "function"
        )
end

local function structural_field(value)
    if type(value) ~= "table" then
        return nil
    end
    for key in pairs(ambiguous_structural_fields) do
        if value[key] ~= nil then
            return key
        end
    end
end

local function ambiguous_handle_like(control, value, kind, name)
    if
        type(value) ~= "table"
        or value.pending == true
        or not has_cancel_api(value)
        or explicit_terminal_result(value)
    then
        return false
    end

    local field = structural_field(value)
    if not field and not allowed_result_field(control, value) then
        return false
    end

    log.add("warn", "provider returned ambiguous handle/result table", {
        kind = kind,
        provider = name,
        field = field,
        message = "set pending=true for async handles or return an explicit result marker",
    })
    return true
end

local function returned_result_like(control, value, handle_mode)
    if value == nil then
        return false
    end
    if control.accept_table_result == true and type(value) == "table" then
        return true
    end
    if handle_mode then
        return explicit_terminal_result(value)
    end
    if type(control.normalize) == "function" then
        return true
    end
    return M.result_like(value) or allowed_result_field(control, value)
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

--- Invoke a provider method and normalize synchronous, async, and cancelable returns.
---@param provider table|fun(...):any Provider table or callback-style provider.
---@param method? string|string[] Provider method name or fallback method names.
---@param context? table Project or request context passed to provider callbacks.
---@param opts? table Provider-specific options passed through to the invocation.
---@param control? table Adapter controls such as timeout, callback position, and result normalizer.
---@return any result Provider result, pending handle, or nil when handle-only invocation cannot start.
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

    local timer = nil
    local normalized_result = nil
    local returned_value = nil
    local returned_proxy = nil

    -- In handle return mode, callers may install the returned value as active
    -- lifecycle state. Never expose invalid scalar handles when `expect_handle`
    -- is set; finish them as terminal invalid results instead.

    local pending
    pending = pending_handle.new({
        kind = kind,
        fields = {
            ok = false,
            provider = name,
            method = selected_method,
        },
        duplicate = function(_, _, source)
            -- Late provider callbacks are common after timeouts or manual
            -- cancellation. The first terminal result wins to keep state
            -- transitions single-shot.
            log.add("warn", "ignored duplicate provider result", {
                kind = kind,
                provider = name,
                source = source,
            })
        end,
        complete = function(raw)
            close_timer(timer)
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
                    reason = (cancel_opts and cancel_opts.reason)
                        or "cancelled",
                    stopped = ok ~= false,
                    message = ("%s provider invocation was cancelled"):format(
                        kind
                    ),
                }
            return ok, finish(terminal, "cancel")
        end,
    })
    local function finish(raw, source)
        return pending.finish(raw, source)
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
        if not timer then
            return
        end
        timer:start(timeout_ms, 0, function()
            schedule(function()
                if pending.result ~= nil then
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
                if pending.result ~= nil then
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
                ok, result = pending_handle.cancel(value, cancel_opts)
            else
                ok, result = cancel_returned(value, cancel_opts)
            end

            if pending.result ~= nil then
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
    local returned_ambiguous_handle =
        ambiguous_handle_like(control, returned, kind, name)
    local returned_handle = type(control.is_handle) == "function"
            and control.is_handle(returned)
        or returned_ambiguous_handle
    local handle_mode = control.return_mode == "handle"
    local returned_result = returned ~= nil
        and not returned_pending
        and not returned_handle
        and returned_result_like(control, returned, handle_mode)

    if
        returned ~= nil
        and control.return_mode == "handle"
        and returned_result
        and pending.result == nil
        and not control.prefer_handle
    then
        finish(returned, "return")
        return returned
    end

    if returned ~= nil and control.return_mode == "handle" then
        if pending.result == nil and async_expected then
            start_timeout()
        end
        if control.expect_handle and pending.result == nil then
            local handle_type = type(returned)
            if handle_type ~= "table" and handle_type ~= "userdata" then
                return finish(
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

    if pending.result ~= nil then
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
