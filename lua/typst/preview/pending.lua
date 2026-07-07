local log = require("typst.core.log")
local pending_handle = require("typst.core.pending")
local preview_results = require("typst.preview.results")
local preview_service = require("typst.project.services.preview")
local resource_manager = require("typst.runtime.resource_manager")
local restart_handle = require("typst.core.restart_handle")
local state = require("typst.preview.state_machine")

local M = {}

M.new = pending_handle.new
M.cancel = pending_handle.cancel

---Subscribe to a preview pending handle with explicit-style support.
---
---Legacy typst-preview.nvim callback handles are dot-style. typst.nvim-owned
---handles set `on_finish_style = "colon"` so they do not rely on guessing.
---@param handle table Pending handle.
---@param callback fun(result:any)
---@return boolean ok True when subscribed.
---@return any result Subscription result or error.
function M.subscribe(handle, callback)
    return pending_handle.subscribe_compatible(handle, callback)
end

local function finish_handle(handle, result, reason)
    if
        type(handle) == "table"
        and handle.pending
        and type(handle.finish) == "function"
    then
        handle:finish(result, reason)
    end
end

---Record and observe a superseded pending-open provider handle.
---@param project table Project state.
---@param provider_handle table Provider pending handle.
---@param result any Cancellation/supersede result.
---@param reason? string Supersede reason.
function M.retain_superseded_open(project, provider_handle, result, reason)
    local token = resource_manager.token(project, "preview.retained_open")
    local entry = state.retain_superseded_open(
        project,
        provider_handle,
        result,
        reason,
        preview_results.compact
    )
    if not entry then
        return
    end

    local subscribed = M.subscribe(provider_handle, function(final)
        if state.token_invalid_reason(token) then
            return
        end
        state.settle_retained_open(
            project,
            entry.id,
            final,
            preview_results.compact
        )
        log.add("debug", "superseded preview open settled", {
            main = project.main,
            reason = entry.reason,
        })
    end)
    if not subscribed then
        state.mark_retained_open_unobservable(project, entry.id)
    end
end

---Observe an async cancellation result for a pending preview open.
---@param project table Project state.
---@param handle table Pending open handle.
---@param generation integer Open generation.
---@param token table? Resource-manager token.
---@param cancel_handle table Cancel pending handle.
---@param reason? string Cancellation reason.
function M.observe_open_cancel(
    project,
    handle,
    generation,
    token,
    cancel_handle,
    reason
)
    if type(cancel_handle) ~= "table" then
        return
    end

    local subscribed = M.subscribe(cancel_handle, function(final)
        local preview = preview_service.get(project) or {}
        if
            state.token_invalid_reason(token)
            or preview.open_handle ~= handle
            or preview.open_generation ~= generation
        then
            return
        end

        local result = vim.tbl_extend(
            "force",
            preview_results.open_cancelled(reason),
            type(final) == "table" and final or {},
            {
                opened = false,
                cancelled = true,
            }
        )

        if preview_results.cancel_confirmed(result) then
            state.clear_pending_open(project, result)
            finish_handle(handle, result, "cancel")
            return
        end

        state.to_open_cancel_unconfirmed(project, result, "open_cancel_failed")
    end)
    if not subscribed then
        state.to_open_cancel_unconfirmed(
            project,
            vim.tbl_extend("force", preview_results.open_cancelled(reason), {
                ok = false,
                reason = "cancel_subscription_failed",
                message = "Pending Typst preview open cancellation could not be observed",
            }),
            "open_cancel_failed"
        )
    end
end

---Record and observe a callback pending-open result.
---@param project table Project state.
---@param opts table Preview options.
---@param result table Provider pending result.
---@return table handle typst.nvim pending handle.
function M.observe_open(project, opts, result)
    local generation = state.next_generation()
    local token = resource_manager.token(project, "preview.open")
    local handle
    handle = pending_handle.new({
        kind = "preview-open",
        handle = result,
        fields = {
            provider_handle = result,
        },
        complete = function(final)
            if
                type(final) == "table"
                and final.cancelled == true
                and final.opened == false
            then
                return final
            end
            local current, reason =
                state.project_open_current(project, handle, generation, token)
            if not current then
                return preview_results.stale_open(final, reason)
            end
            if preview_results.open_failed(final) then
                state.to_open_failed(project, final)
                return final
            end
            return state.to_active_callback(project, opts, final)
        end,
    })
    state.to_opening(project, opts, handle, generation, token)

    local subscribed, subscribe_error = M.subscribe(result, function(final)
        handle:finish(final)
    end)
    if not subscribed then
        local failed = preview_results.unobservable("open", subscribe_error)
        state.to_open_failed(project, failed)
        return failed
    end
    return handle
end

---Cancel the current pending preview open, if one exists.
---@param project table Project state.
---@param opts? table Cancellation options.
---@return table|nil result Cancellation result or nil when no pending open.
function M.cancel_current_open(project, opts)
    opts = opts or {}
    local preview_state = preview_service.get(project) or {}
    if preview_state.opening ~= true then
        return nil
    end

    local handle = preview_state.open_handle
    local generation = preview_state.open_generation
    local token = preview_state.open_token
    local reason = opts.reason or "cancelled"
    local result = preview_results.open_cancelled(reason)

    local provider_handle = type(handle) == "table"
            and (handle.provider_handle or handle.handle)
        or nil
    if
        type(provider_handle) == "table"
        and type(provider_handle.cancel) == "function"
    then
        local stopped, cancel_result = pending_handle.cancel(
            provider_handle,
            { reason = reason },
            {
                style = provider_handle.cancel_style
                    or provider_handle._typst_cancel_style,
            }
        )
        if type(cancel_result) == "table" and cancel_result.pending == true then
            result.provider_result = cancel_result
            result.cancel_pending = true
        elseif
            stopped == false
            or (
                type(cancel_result) == "table"
                and (
                    cancel_result.ok == false
                    or cancel_result.stopped == false
                )
            )
        then
            if type(cancel_result) == "table" then
                result = vim.tbl_extend("force", cancel_result, {
                    ok = false,
                    opened = false,
                    cancel_pending = cancel_result.pending == true or nil,
                    stopped = false,
                    cancelled = true,
                    superseded = true,
                })
            else
                result = {
                    ok = false,
                    opened = false,
                    stopped = false,
                    cancelled = true,
                    reason = "cancel_failed",
                    message = "Pending Typst preview open did not cancel",
                }
            end
        elseif type(cancel_result) == "table" then
            result = vim.tbl_extend("force", result, cancel_result, {
                opened = false,
                stopped = cancel_result.stopped ~= false,
                cancelled = true,
            })
        else
            result.stopped = stopped ~= false
        end
    end

    local supersede = opts.supersede == true or reason == "restart"
    local status = type(result) == "table"
            and result.ok == false
            and "open_cancel_failed"
        or (type(result) == "table" and result.provider_result and result.provider_result.pending == true and "open_cancel_pending")
        or "open_cancel_unconfirmed"

    if
        preview_results.cancel_confirmed(result)
        or supersede
        or opts.force == true
    then
        state.clear_pending_open(project, result)
    else
        state.to_open_cancel_unconfirmed(project, result, status)
    end

    if
        preview_results.cancel_confirmed(result)
        or supersede
        or opts.force == true
    then
        finish_handle(handle, result, "cancel")
    end

    if supersede and not preview_results.cancel_confirmed(result) then
        M.retain_superseded_open(project, provider_handle, result, reason)
    elseif
        not preview_results.cancel_confirmed(result)
        and type(result) == "table"
        and type(result.provider_result) == "table"
        and result.provider_result.pending == true
    then
        M.observe_open_cancel(
            project,
            handle,
            generation,
            token,
            result.provider_result,
            reason
        )
    end

    log.add("info", "pending preview open cancelled", {
        main = project.main,
        reason = reason,
        ok = type(result) ~= "table" or result.ok ~= false,
    })
    return result
end

---Create a restart handle that opens preview after an async stop finishes.
---@param project table Project state.
---@param stop_handle table Stop pending handle.
---@param opts table Preview open options.
---@param open_fn fun(project:table, opts:table):any Open callback.
---@return table handle Restart pending handle.
function M.open_after_stop(project, stop_handle, opts, open_fn)
    local handle =
        restart_handle.new({ kind = "preview" }):set_stop_handle(stop_handle)
    local token = resource_manager.token(project, "preview.restart")

    local function complete_stop(stop_result)
        if handle.result ~= nil or handle.cancel_requested then
            return
        end
        local stale_reason = state.token_invalid_reason(token)
        if stale_reason then
            handle.stopping = false
            handle.ok = false
            handle.reason = stale_reason
            handle:finish(preview_results.stale_open(stop_result, stale_reason))
            return
        end
        handle.stopping = false
        handle.stop_result = stop_result

        if preview_results.stop_failed(stop_result) then
            state.to_stopping_failed(project, stop_result)
            handle.ok = false
            handle.reason = type(stop_result) == "table" and stop_result.reason
                or "stop_failed"
            handle.message = type(stop_result) == "table"
                    and stop_result.message
                or nil
            handle:finish(stop_result)
            return
        end

        local preview_state = preview_service.get(project) or {}
        if preview_state.active == true or preview_state.stopping == true then
            state.emit_stopped(project, "callback", nil, nil)
        end

        local open_opts = vim.deepcopy(opts or {})
        open_opts.restart = false
        open_opts.lifecycle = nil

        local ok, open_result = xpcall(function()
            return open_fn(project, open_opts)
        end, debug.traceback)
        if not ok then
            open_result =
                preview_results.callback_error(project, "open", open_result)
        end

        handle:set_next_handle(open_result)
        if type(open_result) == "table" and open_result.pending == true then
            handle.pending = true
            if type(open_result.on_finish) == "function" then
                local subscribed, subscribe_error = M.subscribe(
                    open_result,
                    function(result)
                        local open_stale = state.token_invalid_reason(token)
                        if open_stale then
                            handle:finish(
                                preview_results.stale_open(result, open_stale)
                            )
                            return
                        end
                        if type(result) == "table" and result.ok == false then
                            state.to_open_failed(project, result)
                        end
                        handle:finish(result)
                    end
                )
                if subscribed then
                    return
                end
                local failed =
                    preview_results.unobservable("open", subscribe_error)
                state.to_open_failed(project, failed)
                handle:finish(failed)
                return
            end
            local failed = preview_results.unobservable("open")
            state.to_open_failed(project, failed)
            handle:finish(failed)
            return
        end

        if type(open_result) == "table" and open_result.ok == false then
            state.to_open_failed(project, open_result)
        end

        handle:finish(open_result)
    end

    if type(stop_handle) == "table" and stop_handle.pending == true then
        if type(stop_handle.on_finish) ~= "function" then
            local failed = preview_results.unobservable("stop")
            state.to_stopping_failed(project, failed)
            handle:finish(failed)
            return handle
        end
        local subscribed, subscribe_error =
            M.subscribe(stop_handle, complete_stop)
        if not subscribed then
            local failed = preview_results.unobservable("stop", subscribe_error)
            state.to_stopping_failed(project, failed)
            handle:finish(failed)
        end
    else
        vim.schedule(function()
            complete_stop(stop_handle)
        end)
    end

    return handle
end

---Build combined native/callback preview refresh payload.
---@param native_result any Native refresh result.
---@param refresh_result any Callback refresh result.
---@return table payload Combined payload.
function M.refresh_payload(native_result, refresh_result)
    local payload = {
        native = native_result,
        callback = refresh_result,
    }
    if type(native_result) == "table" and native_result.ok == false then
        payload.ok = false
        payload.reason = native_result.reason
        payload.message = native_result.message
        payload.error = native_result.error
    end
    return payload
end

---Observe a pending native preview stop.
---@param project table Project state.
---@param pending table Native stop pending result.
---@param stop_fn fun(project:table,result:any):any Final stop handler.
---@return table handle Pending stop handle.
function M.native_stop_after_pending(project, pending, stop_fn)
    if type(pending) ~= "table" or type(pending.on_finish) ~= "function" then
        return pending
    end

    local token = resource_manager.token(project, "preview.stop")
    state.to_stopping(project, { handle = pending })
    local terminal_cancel = false
    local handle
    handle = pending_handle.new({
        kind = "preview-stop",
        handle = pending,
        complete = function(result, _, source_name)
            if source_name == "subscribe" or source_name == "cancel" then
                return result
            end
            local stale_reason = state.token_invalid_reason(token)
            if stale_reason then
                result = preview_results.stale_open(result, stale_reason)
                result.stopped = false
                result.opened = false
                return result
            end
            return stop_fn(project, result)
        end,
        cancel = function(_, opts)
            if type(pending.cancel) ~= "function" then
                return false,
                    {
                        ok = false,
                        reason = "cancel_unavailable",
                        message = "Pending native browser preview stop does not expose cancel",
                        stopped = false,
                    }
            end
            local stopped, cancel_result = pending_handle.cancel(pending, opts, {
                style = pending.cancel_style or pending._typst_cancel_style,
            })
            if type(cancel_result) == "table" and cancel_result.pending == true then
                local subscribed, subscribe_error =
                    M.subscribe(cancel_result, function(final)
                        if handle.finished == true then
                            return
                        end
                        terminal_cancel = true
                        handle:finish(final, "cancel")
                    end)
                if subscribed then
                    return stopped, cancel_result
                end
                terminal_cancel = true
                return false,
                    {
                        ok = false,
                        reason = "cancel_subscription_failed",
                        message = "Pending native browser preview stop cancellation could not be observed",
                        error = subscribe_error,
                        stopped = false,
                    }
            end
            terminal_cancel = true
            return stopped, cancel_result
        end,
    })

    local subscribed, subscribe_error = M.subscribe(pending, function(result)
        if terminal_cancel then
            return
        end
        handle:finish(result)
    end)
    if not subscribed then
        handle:finish({
            ok = false,
            reason = "finish_subscription_failed",
            message = "Pending native browser preview stop could not be observed",
            error = subscribe_error,
        }, "subscribe")
    end

    return handle
end

---Observe a pending native preview refresh.
---@param project table Project state.
---@param native_result table Native pending refresh result.
---@param refresh_result any Callback refresh result.
---@return table handle Pending refresh handle.
function M.native_refresh_after_pending(project, native_result, refresh_result)
    local token = resource_manager.token(project, "preview.refresh")
    local handle = pending_handle.new({
        kind = "preview-refresh",
        handle = native_result,
        fields = M.refresh_payload(native_result, refresh_result),
        complete = function(result)
            local stale_reason = state.token_invalid_reason(token)
            if stale_reason then
                result = preview_results.stale_open(result, stale_reason)
                result.opened = false
            end
            return M.refresh_payload(result, refresh_result)
        end,
        cancel = function(_, opts)
            if type(native_result.cancel) ~= "function" then
                return true,
                    {
                        ok = false,
                        reason = opts and opts.reason or "cancelled",
                        stopped = true,
                    }
            end
            return pending_handle.cancel(native_result, opts, {
                style = native_result.cancel_style
                    or native_result._typst_cancel_style,
            })
        end,
    })

    local subscribed, subscribe_error = M.subscribe(native_result, function(result)
        handle:finish(result)
    end)
    if not subscribed then
        return M.refresh_payload({
            ok = false,
            reason = "finish_subscription_failed",
            message = "Pending native browser preview refresh could not be observed",
            error = subscribe_error,
        }, refresh_result)
    end

    return handle
end

return M
