local async_state = require("typst.core.async_state")
local log = require("typst.core.log")
local pending_handle = require("typst.core.pending")
local core_result = require("typst.core.result")
local tables = require("typst.core.tables")
local provider_lifecycle = require("typst.integrations.provider_lifecycle")

local M = {}

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

local function has_cancel_api(value)
    return type(value) == "table"
        and (
            type(value.cancel) == "function"
            or type(value.stop) == "function"
            or type(value.kill) == "function"
        )
end

local function returned_result_like(control, value, handle_mode)
    if value == nil then
        return false
    end
    if has_cancel_api(value) and not explicit_terminal_result(value) then
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

local function explicit_provider_handle(control, value, handle_mode)
    if type(value) == "table" and value.pending == true then
        return true
    end
    if
        type(value) == "table"
        and value._typst_lifecycle_handle == true
        and not pending_handle.finished(value)
    then
        return true
    end
    if type(control.is_handle) == "function" and control.is_handle(value) then
        return true
    end
    return handle_mode and type(value) == "userdata"
end

local function strict_handle_violation(control, value, handle_mode)
    if type(value) ~= "table" or value.pending == true then
        return false
    end
    if explicit_terminal_result(value) then
        return false
    end
    if allowed_result_field(control, value) and not has_cancel_api(value) then
        return false
    end
    if control.accept_table_result == true then
        return false
    end
    if type(control.is_handle) == "function" and control.is_handle(value) then
        return false
    end
    return handle_mode or type(value.cancel) == "function"
        or type(value.stop) == "function"
        or type(value.kill) == "function"
end

--- Classify a raw provider return value using the adapter contract.
---
--- This is for callers that need to decide whether a value can be installed as
--- active lifecycle state. It mirrors `invoke()` classification without
--- starting timers or normalizing results.
---@param value any Provider return value.
---@param control? table Adapter controls such as `return_mode`, `expect_handle`, `accept_table_result`, `result_fields`, or `is_handle`.
---@return {active_handle:boolean,result_like:boolean,terminal_result:boolean,pending:boolean,invalid_handle:boolean,kind:string}
function M.classify_return(value, control)
    control = control or {}
    local handle_mode = control.return_mode == "handle"
        or control.expect_handle == true
    local pending = type(value) == "table" and value.pending == true
    local explicit_result = explicit_terminal_result(value)
    local provider_handle = explicit_provider_handle(control, value, handle_mode)
    local result_like = value ~= nil
        and not pending
        and returned_result_like(control, value, handle_mode)
    if provider_handle and not explicit_result then
        result_like = false
    end
    local structurally_invalid_table = type(value) == "table"
        and not provider_handle
        and not result_like
        and control.accept_table_result ~= true
    local invalid_handle = value ~= nil
        and value ~= false
        and (
            (
                control.expect_handle == true
                and not provider_handle
                and not result_like
            )
            or strict_handle_violation(control, value, handle_mode)
            or structurally_invalid_table
        )
    local active_handle = value ~= nil
        and value ~= false
        and not result_like
        and provider_handle
        and not invalid_handle

    local kind
    if invalid_handle then
        kind = "invalid_handle"
    elseif active_handle then
        kind = pending and "pending_handle" or "handle"
    elseif result_like then
        kind = "terminal_result"
    else
        kind = "missing"
    end

    return {
        active_handle = active_handle,
        result_like = result_like,
        terminal_result = result_like and not pending,
        pending = pending,
        invalid_handle = invalid_handle,
        kind = kind,
    }
end

--- Return whether a provider value should be stored as live lifecycle state.
---@param value any Provider return value.
---@param control? table Adapter classification controls.
---@return boolean active True when the value is an active provider handle.
function M.is_active_handle(value, control)
    return M.classify_return(value, control).active_handle == true
end

--- Return whether a provider value is a terminal result.
---@param value any Provider return value.
---@param control? table Adapter classification controls.
---@return boolean terminal True when the value is a completed result.
function M.is_terminal_result(value, control)
    return M.classify_return(value, control).terminal_result == true
end

local function invalid_result(kind, name, message, fields)
    message = message
        or ("%s provider returned no result"):format(kind or "tool")
    return core_result.failed(
        "invalid_result",
        message,
        vim.tbl_extend("force", { provider = name }, fields or {})
    )
end

local function provider_error(kind, name, err)
    return core_result.failed("provider_error", tostring(err), {
        provider = name,
        error = tostring(err),
    })
end

local function timeout_result(kind, name, timeout_ms)
    return core_result.timeout({
        provider = name,
        message = ("%s provider timed out after %dms"):format(
            kind or "tool",
            timeout_ms or 0
        ),
    })
end

local function provider_cancel_result(kind, cancel_opts, stopped, result)
    if type(result) == "table" and M.result_like(result) then
        return result
    end
    return core_result.failed(
        (cancel_opts and cancel_opts.reason) or core_result.reason.cancelled,
        ("%s provider invocation was cancelled"):format(kind),
        {
            cancelled = true,
            stopped = stopped ~= false,
        }
    )
end

local function strict_contract_result(kind, name, handle_mode, classification)
    return invalid_result(
        kind,
        name,
        ("%s provider returned an invalid %s"):format(
            kind,
            handle_mode and "handle" or "result"
        ),
        {
            contract = "provider-result-v1",
            classification = classification,
        }
    )
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

    local normalized_result = nil
    -- In handle return mode, callers may install the returned value as active
    -- lifecycle state. Never expose invalid scalar handles when `expect_handle`
    -- is set; finish them as terminal invalid results instead.
    local lifecycle = provider_lifecycle.new({
        kind = kind,
        provider_name = name,
        method = selected_method,
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
            normalized_result = normalize_result(control, raw, name)
            protected_callback(control, normalized_result, context)
            return normalized_result
        end,
        cancel_result = function(cancel_opts, stopped, result)
            return provider_cancel_result(kind, cancel_opts, stopped, result)
        end,
        timeout_reason = core_result.reason.timeout,
        timeout_result = function(timeout_ms, cancel_ok, cancel_result)
            local timed_out = timeout_result(kind, name, timeout_ms)
            if type(cancel_result) == "table" then
                timed_out.cancel_result = cancel_result
                if
                    cancel_ok == true
                    or core_result.is_confirmed_stopped(cancel_result)
                then
                    timed_out.stopped = true
                end
            elseif cancel_ok == true then
                timed_out.stopped = true
            end
            return timed_out
        end,
        cancel_timeout_ms = control.cancel_timeout_ms,
        cancel_timeout_result = function(timeout_ms, cancel_result)
            return core_result.failed(
                core_result.reason.cancel_unconfirmed,
                ("%s provider cancellation did not finish after timeout"):format(
                    kind
                ),
                {
                    provider = name,
                    stopped = false,
                    timeout = true,
                    cancel_timeout_ms = timeout_ms,
                    cancel_result = cancel_result,
                }
            )
        end,
    })
    local pending = lifecycle.pending

    local function finish(raw, source)
        return lifecycle.finish(raw, source)
    end

    local function provider_callback(raw)
        return lifecycle.callback(raw)
    end

    -- Start timeouts only after provider invocation so a provider that calls back
    -- synchronously is returned as a result, not briefly exposed as pending.
    local function start_timeout()
        lifecycle.start_timeout(control.timeout_ms)
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

    lifecycle.set_returned(returned)

    local timeout_configured = tonumber(control.timeout_ms)
        and tonumber(control.timeout_ms) > 0
    local async_expected = control.async ~= false
        and (type(control.on_result) == "function" or timeout_configured)
    local handle_mode = control.return_mode == "handle"
    local returned_class = M.classify_return(returned, control)
    local returned_pending = returned_class.pending == true
    local returned_handle = returned_class.active_handle == true
    local returned_result = returned_class.terminal_result == true
    local invalid_return = returned_class.invalid_handle == true

    if pending.result ~= nil then
        if
            control.return_mode == "handle"
            and returned_handle
            and type(normalized_result) == "table"
            and core_result.is_unconfirmed_stop(normalized_result)
        then
            return returned
        end
        return normalized_result
    end

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

    if invalid_return then
        return finish(
            strict_contract_result(
                kind,
                name,
                handle_mode,
                returned_class.kind
            ),
            "strict_contract"
        )
    end

    if returned ~= nil and control.return_mode == "handle" then
        if pending.result == nil and async_expected then
            start_timeout()
        end
        if returned_pending then
            return lifecycle.proxy_for(returned)
        end
        return returned
    end

    if returned ~= nil and returned_result then
        return finish(returned, "return")
    end

    if returned_pending or returned_handle then
        if async_expected then
            start_timeout()
        end
        if returned_pending and type(returned) == "table" then
            return lifecycle.proxy_for(returned)
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
