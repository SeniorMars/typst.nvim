local async = require("typst.core.async")
local clients = require("typst.integrations.tinymist.clients")
local log = require("typst.core.log")
local position = require("typst.integrations.tinymist.position")
local request_async = require("typst.integrations.tinymist.async")

local M = {}

-- Thin Tinymist LSP feature facade.
--
-- This module intentionally does not open buffers, apply edits, or make picker
-- decisions. It only builds conservative LSP params and normalizes results so
-- higher layers can decide whether the data belongs in UI, quickfix, or the
-- project index.

local function async_required(method)
    return {
        ok = false,
        reason = "async_required",
        provider = "tinymist",
        method = method,
        message = "Tinymist feature requests require a callback",
    }
end

local function normalize_bufnr(bufnr)
    if bufnr == nil or bufnr == 0 then
        return vim.api.nvim_get_current_buf()
    end
    return bufnr
end

local function protected_callback(callback, result)
    local ok, err = pcall(callback, result)
    if not ok then
        log.add("error", "Tinymist feature callback failed", {
            error = err,
        })
    end
end

local function immediate(callback, result)
    async.schedule(function()
        protected_callback(callback, result)
    end)
    return result
end

local function text_document_params(bufnr)
    return {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
    }
end

local function position_request_params(bufnr, client, opts)
    return position.position_params(bufnr, client, opts)
end

local function selection_range_params(bufnr, client, opts)
    if type(opts.positions) == "table" then
        return vim.tbl_extend("force", text_document_params(bufnr), {
            positions = opts.positions,
        })
    end

    local params = position_request_params(bufnr, client, opts)
    if not params then
        return nil
    end
    return {
        textDocument = params.textDocument,
        positions = { params.position },
    }
end

local function normalize_raw(method, key, result, client)
    local payload = result or {}
    local normalized = {
        ok = result ~= nil,
        provider = "tinymist",
        client = client.name,
        encoding = client.offset_encoding or "utf-16",
        method = method,
        result = result,
    }
    normalized[key] = payload
    if type(payload) == "table" and payload[1] ~= nil then
        normalized.count = #payload
    end
    return normalized
end

local function normalize_signature(result, client)
    return {
        ok = result ~= nil,
        provider = "tinymist",
        client = client.name,
        encoding = client.offset_encoding or "utf-16",
        method = "textDocument/signatureHelp",
        result = result,
        signature_help = result,
        signatures = type(result) == "table" and result.signatures or nil,
        active_signature = type(result) == "table" and result.activeSignature
            or nil,
        active_parameter = type(result) == "table" and result.activeParameter
            or nil,
    }
end

local function normalize_on_enter(result, client)
    local edits = result
    if type(result) == "table" and result.edit ~= nil then
        edits = result.edit
    end
    return {
        ok = result ~= nil,
        provider = "tinymist",
        client = client.name,
        encoding = client.offset_encoding or "utf-16",
        method = "experimental/onEnter",
        result = result,
        edits = edits,
    }
end

--- Check whether an attached Tinymist client advertises an LSP method.
---@param bufnr? integer Buffer whose attached clients should be inspected.
---@param method string LSP method name.
---@return boolean supported True when any attached Tinymist client supports it.
function M.supports(bufnr, method)
    bufnr = normalize_bufnr(bufnr)
    for _, client in ipairs(clients.clients(bufnr)) do
        if clients.supports_method(client, method, bufnr) then
            return true
        end
    end
    return false
end

--- Send a guarded Tinymist request and normalize the raw response.
---@param bufnr? integer Buffer used for client selection and guards.
---@param method string LSP method name.
---@param opts? table Request options; accepts `params`, `params_for_client`, and `normalize`.
---@param callback? fun(result:table) Callback that receives the normalized result.
---@return table result Pending handle or immediate failure payload.
function M.request(bufnr, method, opts, callback)
    bufnr = normalize_bufnr(bufnr)
    opts = opts or {}
    callback = callback or opts.callback
    if type(callback) ~= "function" then
        return async_required(method)
    end

    local params_for_client = opts.params_for_client
    if type(params_for_client) ~= "function" then
        params_for_client = function()
            if type(opts.params) == "table" then
                return vim.deepcopy(opts.params)
            end
            return text_document_params(bufnr)
        end
    end

    return request_async.request(
        bufnr,
        method,
        params_for_client,
        opts,
        callback,
        function(result, client, params)
            if type(opts.normalize) == "function" then
                return opts.normalize(result, client, params)
            end
            return {
                ok = result ~= nil,
                provider = "tinymist",
                client = client.name,
                method = method,
                result = result,
            }
        end
    )
end

--- Request document highlights for the current or supplied position.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.document_highlight(bufnr, opts)
    opts = opts or {}
    local target = normalize_bufnr(bufnr)
    return M.request(bufnr, "textDocument/documentHighlight", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = opts.guard_cursor,
        guard_generation = opts.guard_generation,
        pos = opts.pos,
        position = opts.position,
        timeout_ms = opts.timeout_ms,
        params_for_client = function(client)
            return position_request_params(target, client, opts)
        end,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/documentHighlight",
                "highlights",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request document links for a buffer.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.document_links(bufnr, opts)
    opts = opts or {}
    return M.request(bufnr, "textDocument/documentLink", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = false,
        guard_generation = opts.guard_generation,
        timeout_ms = opts.timeout_ms,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/documentLink",
                "links",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request LSP folding ranges for a buffer.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.folding_ranges(bufnr, opts)
    opts = opts or {}
    return M.request(bufnr, "textDocument/foldingRange", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = false,
        guard_generation = opts.guard_generation,
        timeout_ms = opts.timeout_ms,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/foldingRange",
                "ranges",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request signature help at the current or supplied position.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.signature_help(bufnr, opts)
    opts = opts or {}
    local target = normalize_bufnr(bufnr)
    return M.request(bufnr, "textDocument/signatureHelp", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = opts.guard_cursor,
        guard_generation = opts.guard_generation,
        pos = opts.pos,
        position = opts.position,
        timeout_ms = opts.timeout_ms,
        params_for_client = function(client)
            return position_request_params(target, client, opts)
        end,
        normalize = normalize_signature,
    }, opts.callback)
end

--- Request document colors for a buffer.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.document_color(bufnr, opts)
    opts = opts or {}
    return M.request(bufnr, "textDocument/documentColor", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = false,
        guard_generation = opts.guard_generation,
        timeout_ms = opts.timeout_ms,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/documentColor",
                "colors",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request color presentations for one color literal range.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options with `color`, `range`, and required `callback`.
---@return table result Pending handle or immediate failure payload.
function M.color_presentation(bufnr, opts)
    opts = opts or {}
    local target = normalize_bufnr(bufnr)
    local callback = opts.callback
    if type(callback) ~= "function" then
        return async_required("textDocument/colorPresentation")
    end
    if type(opts.color) ~= "table" then
        return immediate(callback, {
            ok = false,
            reason = "missing_color",
            provider = "tinymist",
            method = "textDocument/colorPresentation",
            message = "Tinymist colorPresentation requires a color",
        })
    end
    if type(opts.range) ~= "table" then
        return immediate(callback, {
            ok = false,
            reason = "missing_range",
            provider = "tinymist",
            method = "textDocument/colorPresentation",
            message = "Tinymist colorPresentation requires a range",
        })
    end

    return M.request(bufnr, "textDocument/colorPresentation", {
        callback = callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = false,
        guard_generation = opts.guard_generation,
        timeout_ms = opts.timeout_ms,
        params_for_client = function()
            return vim.tbl_extend("force", text_document_params(target), {
                color = opts.color,
                range = opts.range,
            })
        end,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/colorPresentation",
                "presentations",
                result,
                client
            )
        end,
    }, callback)
end

--- Request code lenses for a buffer.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; `callback` is required.
---@return table result Pending handle or immediate failure payload.
function M.code_lens(bufnr, opts)
    opts = opts or {}
    return M.request(bufnr, "textDocument/codeLens", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = false,
        guard_generation = opts.guard_generation,
        timeout_ms = opts.timeout_ms,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/codeLens",
                "lenses",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request semantic selection ranges for one or more positions.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; accepts `position`, `pos`, or `positions`.
---@return table result Pending handle or immediate failure payload.
function M.selection_range(bufnr, opts)
    opts = opts or {}
    local target = normalize_bufnr(bufnr)
    return M.request(bufnr, "textDocument/selectionRange", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = opts.guard_cursor,
        guard_generation = opts.guard_generation,
        pos = opts.pos,
        position = opts.position,
        timeout_ms = opts.timeout_ms,
        params_for_client = function(client)
            return selection_range_params(target, client, opts)
        end,
        normalize = function(result, client)
            return normalize_raw(
                "textDocument/selectionRange",
                "ranges",
                result,
                client
            )
        end,
    }, opts.callback)
end

--- Request Tinymist's experimental Enter handling without applying edits.
---@param bufnr? integer Buffer to query.
---@param opts? table Request options; accepts `position` or `pos`.
---@return table result Pending handle or immediate failure payload.
function M.on_enter(bufnr, opts)
    opts = opts or {}
    local target = normalize_bufnr(bufnr)
    return M.request(bufnr, "experimental/onEnter", {
        callback = opts.callback,
        client = opts.client,
        guard_changedtick = opts.guard_changedtick,
        guard_cursor = opts.guard_cursor,
        guard_generation = opts.guard_generation,
        pos = opts.pos,
        position = opts.position,
        timeout_ms = opts.timeout_ms,
        params_for_client = function(client)
            return position_request_params(target, client, opts)
        end,
        normalize = normalize_on_enter,
    }, opts.callback)
end

return M
