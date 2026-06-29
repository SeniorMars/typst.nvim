local async = require("typst.core.async")

local M = {}

--- Normalize Neovim LSP client.request return values.
---
--- Neovim has returned both `true, request_id` and, in some adapters/tests,
--- a numeric request id as the first return value. Keep that compatibility in
--- one place so callers can reliably cancel the actual request id.
---@param called boolean Whether `client.request` returned without throwing.
---@param request_ok any First return value from `client.request`, or thrown error.
---@param returned_id any Second return value from `client.request`.
---@return table result Normalized start result.
function M.normalize_start(called, request_ok, returned_id)
    if not called then
        return {
            ok = false,
            called = false,
            reason = "request_failed",
            message = tostring(request_ok),
            error = request_ok,
        }
    end

    local request_id = nil
    if type(request_ok) == "number" and returned_id == nil then
        request_id = request_ok
        request_ok = true
    elseif request_ok == true then
        request_id = returned_id
    end

    if request_ok == false or request_ok == nil then
        return {
            ok = false,
            called = true,
            reason = "request_failed",
            request_ok = request_ok,
            request_id = request_id,
        }
    end

    return {
        ok = true,
        called = true,
        request_ok = request_ok,
        request_id = request_id,
    }
end

--- Start an LSP request and normalize request-id return handling.
---@param client table LSP client object.
---@param method string LSP method name.
---@param params table Request params.
---@param handler? function LSP response handler.
---@param bufnr? integer Buffer number.
---@return table result Normalized start result.
function M.start(client, method, params, handler, bufnr)
    if not client or type(client.request) ~= "function" then
        return {
            ok = false,
            called = false,
            reason = "request_unavailable",
            method = method,
            message = "LSP client does not support request",
        }
    end

    local called, request_ok, returned_id =
        pcall(client.request, client, method, params, handler, bufnr)
    local result = M.normalize_start(called, request_ok, returned_id)
    result.client = client
    result.method = method
    return result
end

--- Cancel an in-flight request from a normalized start result or client/id.
---@param start_or_client table? Normalized result from `start()` or LSP client.
---@param request_id any Optional request id when passing a client.
---@return boolean cancelled True when cancellation was accepted.
function M.cancel(start_or_client, request_id)
    if type(start_or_client) == "table" and start_or_client.client then
        return async.cancel_lsp_request(
            start_or_client.client,
            start_or_client.request_id
        )
    end
    return async.cancel_lsp_request(start_or_client, request_id)
end

return M
