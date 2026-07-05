local clients = require("typst.integrations.tinymist.clients")
local async = require("typst.core.async")
local lsp_request = require("typst.core.lsp_request")
local request_async = require("typst.integrations.tinymist.async")
local position = require("typst.integrations.tinymist.position")
local symbols = require("typst.integrations.tinymist.symbols")

local M = {}
local uv = vim.uv or vim.loop
local format_generations = {}

local function async_required(method)
    return {
        ok = false,
        reason = "async_required",
        provider = "tinymist",
        method = method,
        message = "Tinymist Neovim LSP requests require a callback",
    }
end

local schedule = async.schedule
local close_timer = async.close_timer

local function next_format_generation(bufnr, opts)
    if opts.guard_generation == false then
        return nil
    end

    format_generations[bufnr] = (format_generations[bufnr] or 0) + 1
    return format_generations[bufnr]
end

local function stale_format_generation(bufnr, generation)
    return generation ~= nil and format_generations[bufnr] ~= generation
end

--- Request Tinymist hover information at the current or supplied position.
---@param bufnr? integer Buffer whose cursor/position should be queried.
---@param opts? table Request options; `callback` receives the normalized result.
---@return table? pending Async request handle, or nil when no callback is provided.
function M.hover(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/hover",
            function(client)
                return position.position_params(bufnr, client, opts)
            end,
            opts,
            opts.callback,
            function(result)
                return {
                    ok = result ~= nil,
                    result = result,
                    hover = result,
                }
            end
        )
    end

    return nil
end

--- Request Tinymist definition information at the current or supplied position.
---@param bufnr? integer Buffer whose cursor/position should be queried.
---@param opts? table Request options; `callback` receives the normalized result.
---@return table? pending Async request handle, or nil when no callback is provided.
function M.definition(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/definition",
            function(client)
                return position.position_params(bufnr, client, opts)
            end,
            opts,
            opts.callback,
            function(result)
                return {
                    ok = result ~= nil,
                    result = result,
                    definition = result,
                }
            end
        )
    end

    return nil
end

--- Request Tinymist references and normalize returned locations.
---@param bufnr? integer Buffer whose cursor/position should be queried.
---@param opts? table Request options; `callback` receives the normalized result.
---@return table? pending Async request handle, or nil when no callback is provided.
function M.references(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/references",
            function(client)
                local params = position.position_params(bufnr, client, opts)
                if not params then
                    return nil
                end
                params.context = {
                    includeDeclaration = opts.include_declaration ~= false,
                }
                return params
            end,
            opts,
            opts.callback,
            function(result, client)
                return {
                    ok = result ~= nil,
                    result = result,
                    references = symbols.normalize_locations(result, {
                        bufnr = bufnr,
                        encoding = client.offset_encoding or "utf-16",
                    }),
                }
            end
        )
    end

    return nil
end

--- Request Tinymist rename and optionally apply the returned workspace edit.
---@param bufnr? integer Buffer whose cursor/position should be renamed.
---@param new_name string New symbol name to pass to Tinymist.
---@param opts? table Rename options; `callback` enables async execution and `apply=false` previews edits.
---@return table? result Pending request handle or immediate failure payload.
function M.rename(bufnr, new_name, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}
    new_name = vim.trim(new_name or "")

    if new_name == "" then
        return {
            ok = false,
            reason = "empty_name",
            provider = "tinymist",
            message = "Rename target is empty",
        }
    end

    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/rename",
            function(client)
                local params = position.position_params(bufnr, client, opts)
                if not params then
                    return nil
                end
                params.newName = new_name
                return params
            end,
            opts,
            opts.callback,
            function(result, client)
                if not result then
                    return {
                        ok = false,
                        reason = "empty_result",
                        provider = "tinymist",
                        client = client.name,
                        message = "Tinymist rename returned no edits",
                    }
                end

                if opts.apply ~= false then
                    vim.lsp.util.apply_workspace_edit(
                        result,
                        client.offset_encoding or "utf-16"
                    )
                end

                return {
                    ok = true,
                    provider = "tinymist",
                    client = client.name,
                    edit = result,
                    new_name = new_name,
                    applied = opts.apply ~= false,
                }
            end
        )
    end

    if not clients.available(bufnr) then
        return {
            ok = false,
            reason = "no_client",
            provider = "tinymist",
            message = "Tinymist Neovim LSP client is not attached",
        }
    end

    return async_required("textDocument/rename")
end

local function format_params(bufnr, opts)
    return {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        options = opts.options or position.formatting_options(bufnr),
    }
end

local function format_result(bufnr, client, edits, opts, started_tick)
    edits = type(edits) == "table" and edits or {}
    if opts.apply ~= false and #edits > 0 then
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return {
                ok = false,
                reason = "invalid_buffer",
                provider = "tinymist",
                client = client.name,
                message = "Formatted buffer no longer exists",
            }
        end

        if type(opts.apply_guard) == "function" then
            local guarded = opts.apply_guard()
            if guarded then
                guarded.provider = "tinymist"
                guarded.client = client.name
                guarded.edits = #edits
                return guarded
            end
        elseif
            started_tick
            and vim.api.nvim_buf_get_changedtick(bufnr) ~= started_tick
        then
            return {
                ok = false,
                reason = "buffer_changed",
                provider = "tinymist",
                client = client.name,
                message = "Buffer changed while formatting",
            }
        end

        vim.lsp.util.apply_text_edits(
            edits,
            bufnr,
            client.offset_encoding or "utf-16"
        )
    end

    return {
        ok = true,
        provider = "tinymist",
        client = client.name,
        edits = #edits,
        changed = #edits > 0,
    }
end

local function async_format(bufnr, client, request_params, opts, callback)
    local completed = false
    local request_id = nil
    local timeout_ms = opts.timeout_ms or 10000
    local started_tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local generation = next_format_generation(bufnr, opts)
    local timer = nil
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
        callback(result)
        return result
    end

    local function drop_stale()
        if completed or not stale_format_generation(bufnr, generation) then
            return false
        end
        completed = true
        close_timer(timer)
        return true
    end

    if timeout_ms and timeout_ms > 0 then
        timer = uv.new_timer()
        if timer then
            timer:start(timeout_ms, 0, function()
                schedule(function()
                    if completed then
                        return
                    end
                    if drop_stale() then
                        return
                    end
                    cancel_request()
                    finish({
                        ok = false,
                        reason = "timeout",
                        provider = "tinymist",
                        client = client.name,
                        message = ("Tinymist formatting timed out after %dms"):format(
                            timeout_ms
                        ),
                    })
                end)
            end)
        end
    end

    local request_start = lsp_request.start(
        client,
        "textDocument/formatting",
        request_params,
        function(err, result)
            schedule(function()
                if drop_stale() then
                    return
                end

                if err then
                    finish({
                        ok = false,
                        reason = "lsp_error",
                        provider = "tinymist",
                        client = client.name,
                        message = tostring(err),
                        error = err,
                    })
                    return
                end

                finish(format_result(bufnr, client, result, opts, started_tick))
            end)
        end,
        bufnr
    )

    if not request_start.ok and request_start.called == false then
        close_timer(timer)
        return nil,
            {
                ok = false,
                reason = "request_failed",
                provider = "tinymist",
                client = client.name,
                message = request_start.message,
                error = request_start.error,
            }
    end

    request_id = request_start.request_id
    if not request_start.ok then
        close_timer(timer)
        return nil,
            {
                ok = false,
                reason = "request_failed",
                provider = "tinymist",
                client = client.name,
                message = "Tinymist formatting request failed",
            }
    end

    pending = {
        ok = false,
        pending = true,
        provider = "tinymist",
        client = client.name,
        cancel = function(self_or_opts, maybe_opts)
            local cancel_opts = maybe_opts
            if self_or_opts ~= pending then
                cancel_opts = self_or_opts
            end
            cancel_request()
            finish({
                ok = false,
                reason = (cancel_opts and cancel_opts.reason) or "cancelled",
                provider = "tinymist",
                client = client.name,
                stopped = true,
                message = "Tinymist formatting was cancelled",
            })
            return true
        end,
    }
    return pending
end

--- Request Tinymist document formatting for a buffer.
---@param bufnr? integer Buffer to format.
---@param opts? table Formatting options; `apply=false` returns edits without applying them.
---@param callback? fun(result:table) Async formatting result callback.
---@return table result Pending handle or immediate failure payload.
function M.format(bufnr, opts, callback)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    local saw_client = false
    for _, client in ipairs(clients.clients(bufnr)) do
        saw_client = true
        if
            type(client.request) == "function"
            and clients.supports_method(
                client,
                "textDocument/formatting",
                bufnr
            )
        then
            local request_params = format_params(bufnr, opts)
            if callback and type(client.request) == "function" then
                local pending, failure =
                    async_format(bufnr, client, request_params, opts, callback)
                return pending
                    or failure
                    or {
                        ok = false,
                        reason = "request_failed",
                        provider = "tinymist",
                        message = "Tinymist formatting request did not return a result",
                    }
            end
            return async_required("textDocument/formatting")
        end
    end

    if not saw_client then
        return {
            ok = false,
            reason = "no_client",
            provider = "tinymist",
            message = "Tinymist Neovim LSP client is not attached",
        }
    end

    return {
        ok = false,
        reason = "unsupported",
        provider = "tinymist",
        message = "Tinymist formatting is unavailable",
    }
end

return M
