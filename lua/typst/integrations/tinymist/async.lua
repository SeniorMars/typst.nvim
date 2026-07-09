local async = require("typst.core.async")
local async_state = require("typst.core.async_state")
local lsp_request = require("typst.core.lsp_request")
local clients = require("typst.integrations.tinymist.clients")
local log = require("typst.core.log")
local resource_manager = require("typst.runtime.resource_manager")
local windows = require("typst.core.windows")

local M = {}
local uv = vim.uv or vim.loop
local generations = {}

-- Shared async guard for Tinymist requests.
--
-- Many callers use Tinymist to refine an immediate local result. A late answer
-- must not rewrite UI state after the buffer changed, the cursor moved, or a
-- newer request superseded it.

local schedule = async.schedule
local close_timer = async.close_timer

function M.reset()
    generations = {}
end

local function current_cursor(bufnr)
    local winid = windows.for_buffer(bufnr)
    if not winid then
        return nil
    end

    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok and cursor then
        return { cursor[1], cursor[2] }
    end
end

local function generation_key(bufnr, method)
    return ("%s\n%s"):format(bufnr, method)
end

local function next_generation(bufnr, method, opts)
    if opts.guard_generation == false then
        return nil
    end

    local key = generation_key(bufnr, method)
    generations[key] = (generations[key] or 0) + 1
    return generations[key]
end

local function request_project(bufnr, opts)
    return type(opts.project) == "table" and opts.project
        or clients.project_for_buffer(bufnr)
end

local function capture_guard(bufnr, method, opts)
    opts = opts or {}
    local project = type(opts.project) == "table" and opts.project
        or clients.project_for_buffer(bufnr)
    local guard = {
        bufnr = bufnr,
        method = method,
        changedtick = nil,
        cursor = nil,
        generation = next_generation(bufnr, method, opts),
        epoch_token = resource_manager.token(
            project,
            ("tinymist:%s"):format(method)
        ),
    }

    if vim.api.nvim_buf_is_valid(bufnr) then
        guard.changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    end

    if
        opts.guard_cursor ~= false
        and opts.pos == nil
        and opts.position == nil
    then
        -- Cursor-sensitive requests guard the live window position. Requests
        -- that pass an explicit position are stable without this extra check.
        guard.cursor = current_cursor(bufnr)
    end

    return guard
end

local function stale_result(guard, opts)
    opts = opts or {}
    local bufnr = guard.bufnr
    local valid_token, token_reason =
        resource_manager.valid_token(guard.epoch_token)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        if not valid_token and token_reason == "reset" then
            return {
                ok = false,
                reason = "reset",
                provider = "tinymist",
                message = "Tinymist response arrived after typst.nvim reset",
                stale = true,
            }
        end

        return {
            ok = false,
            reason = "invalid_buffer",
            provider = "tinymist",
            message = "Tinymist response arrived after the buffer was deleted",
            stale = true,
        }
    end

    if not valid_token then
        return {
            ok = false,
            reason = token_reason or "stale_request",
            provider = "tinymist",
            message = token_reason == "reset"
                    and "Tinymist response arrived after typst.nvim reset"
                or "Tinymist response arrived after the project changed",
            stale = true,
        }
    end

    if
        opts.guard_changedtick ~= false
        and guard.changedtick
        and vim.api.nvim_buf_get_changedtick(bufnr) ~= guard.changedtick
    then
        return {
            ok = false,
            reason = "buffer_changed",
            provider = "tinymist",
            message = "Tinymist response arrived after the buffer changed",
            stale = true,
        }
    end

    if
        guard.generation
        and generations[generation_key(bufnr, guard.method)]
            ~= guard.generation
    then
        return {
            ok = false,
            reason = "stale_request",
            provider = "tinymist",
            message = "Tinymist response arrived after a newer request",
            stale = true,
        }
    end

    local cursor = guard.cursor and current_cursor(bufnr) or nil
    if
        cursor
        and (cursor[1] ~= guard.cursor[1] or cursor[2] ~= guard.cursor[2])
    then
        return {
            ok = false,
            reason = "cursor_moved",
            provider = "tinymist",
            message = "Tinymist response arrived after the cursor moved",
            stale = true,
        }
    end
end

local function protected_callback(callback, ...)
    local ok, err = pcall(callback, ...)
    if not ok then
        log.add("error", "Tinymist async callback failed", {
            error = err,
        })
    end
end

local function selection_failure(method, selection)
    return vim.tbl_extend("force", {
        ok = false,
        provider = "tinymist",
        method = method,
        reason = "no_client",
        message = "Tinymist Neovim LSP client is not attached",
    }, selection or {})
end

--- Send an asynchronous Tinymist LSP request with timeout and staleness guards.
---@param bufnr? integer Buffer used for client selection and changedtick guards.
---@param method string LSP method name to request.
---@param params_for_client fun(client:table):table|nil Function building request params for each candidate client.
---@param opts? table Request controls such as timeout, client override, and buffer guards.
---@param callback fun(result:typst.ProviderResult|table) Callback invoked once with the normalized result.
---@param normalize? fun(err:any, result:any, client:table):typst.ProviderResult|table Result normalizer for raw LSP callback values.
---@return typst.ProviderCancelHandle|typst.ProviderResult|table|nil result Pending cancel handle, immediate failure, or nil when no client is usable.
function M.request(bufnr, method, params_for_client, opts, callback, normalize)
    opts = opts or {}
    if type(callback) ~= "function" then
        error("typst.nvim: Tinymist async request requires a callback")
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local selected = clients.select_client({
        bufnr = bufnr,
        project = request_project(bufnr, opts),
        client = opts.client,
        method = method,
        request = "async",
    })
    if not selected.ok then
        local result = selection_failure(method, selected)
        schedule(function()
            protected_callback(callback, result)
        end)
        return result
    end

    local client = selected.client
    local params_ok, params_or_err = pcall(params_for_client, client)
    if not params_ok then
        local result = {
            ok = false,
            reason = "request_failed",
            provider = "tinymist",
            client = client.name,
            method = method,
            message = ("Tinymist %s request parameters failed: %s"):format(
                method,
                tostring(params_or_err)
            ),
            error = params_or_err,
        }
        schedule(function()
            protected_callback(callback, result, client)
        end)
        return result
    end

    local params = params_or_err
    if not params then
        local result = {
            ok = false,
            reason = "missing_position",
            provider = "tinymist",
            client = client.name,
            method = method,
            message = "Tinymist request requires a cursor position",
        }
        schedule(function()
            protected_callback(callback, result, client)
        end)
        return result
    end

    local timeout_ms = opts.timeout_ms or 1000
    local completed = false
    local request_id = nil
    local timer = nil
    local guard = capture_guard(bufnr, method, opts)
    local pending

    local function cancel_request()
        if request_id and type(client.cancel_request) == "function" then
            pcall(client.cancel_request, client, request_id)
        end
    end

    local function finish(result)
        if completed then
            return result
        end
        completed = true
        close_timer(timer)
        result.provider = result.provider or "tinymist"
        result.client = result.client or client.name
        result.method = result.method or method
        protected_callback(callback, result, client)
        return result
    end

    if timeout_ms and timeout_ms > 0 then
        timer = uv.new_timer()
        if timer then
            timer:start(timeout_ms, 0, function()
                schedule(function()
                    if completed then
                        return
                    end
                    -- Ask the client to cancel before reporting timeout;
                    -- finish() will ignore any later LSP callback.
                    cancel_request()
                    finish({
                        ok = false,
                        reason = "timeout",
                        provider = "tinymist",
                        client = client.name,
                        method = method,
                        message = ("Tinymist %s timed out after %dms"):format(
                            method,
                            timeout_ms
                        ),
                    })
                end)
            end)
        end
    end

    local start = lsp_request.start(
        client,
        method,
        params,
        function(err, result)
            schedule(function()
                if err then
                    finish({
                        ok = false,
                        reason = "lsp_error",
                        provider = "tinymist",
                        client = client.name,
                        method = method,
                        message = tostring(err),
                        error = err,
                    })
                    return
                end

                local stale = stale_result(guard, opts)
                if stale then
                    stale.client = client.name
                    stale.method = method
                    finish(stale)
                    return
                end

                if type(normalize) == "function" then
                    local ok_norm, normalized = async_state.protect(function()
                        return normalize(result, client, params)
                    end)
                    if ok_norm and type(normalized) == "table" then
                        finish(normalized)
                    else
                        finish({
                            ok = false,
                            reason = "normalize_failed",
                            provider = "tinymist",
                            client = client.name,
                            method = method,
                            message = ok_norm
                                    and "Tinymist response normalizer returned no result"
                                or tostring(normalized),
                            error = tostring(normalized),
                        })
                    end
                else
                    finish({
                        ok = result ~= nil,
                        result = result,
                    })
                end
            end)
        end,
        bufnr
    )

    if not start.ok and start.called == false then
        close_timer(timer)
        local result = {
            ok = false,
            reason = "request_failed",
            provider = "tinymist",
            client = client.name,
            method = method,
            message = start.message,
            error = start.error,
        }
        schedule(function()
            protected_callback(callback, result, client)
        end)
        return result
    end

    request_id = start.request_id
    if not start.ok then
        close_timer(timer)
        local result = {
            ok = false,
            reason = "request_failed",
            provider = "tinymist",
            client = client.name,
            method = method,
            message = ("Tinymist %s request failed"):format(method),
        }
        schedule(function()
            protected_callback(callback, result, client)
        end)
        return result
    end

    pending = {
        ok = false,
        pending = true,
        provider = "tinymist",
        client = client.name,
        method = method,
        cancel = function(self_or_opts, maybe_opts)
            local cancel_opts = maybe_opts
            if self_or_opts ~= pending then
                cancel_opts = self_or_opts
            end
            -- Expose cancellation on the pending result so callers that abandon
            -- a UI action can also abandon the LSP request.
            cancel_request()
            finish({
                ok = false,
                reason = (cancel_opts and cancel_opts.reason) or "cancelled",
                provider = "tinymist",
                client = client.name,
                method = method,
                stopped = true,
                message = ("Tinymist %s request was cancelled"):format(method),
            })
            return true
        end,
    }
    return pending
end

return M
