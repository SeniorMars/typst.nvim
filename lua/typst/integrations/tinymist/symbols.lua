local clients = require("typst.integrations.tinymist.clients")
local request_async = require("typst.integrations.tinymist.async")
local tables = require("typst.core.tables")
local position = require("typst.integrations.tinymist.position")

local M = {}

local function uri_to_fname(uri)
    if not uri then
        return nil
    end

    local ok, path = pcall(vim.uri_to_fname, uri)
    if ok then
        return path
    end

    return nil
end

local function symbol_range(symbol, context)
    context = context or {}
    local encoding = context.encoding or "utf-16"

    if symbol.location then
        local path = uri_to_fname(symbol.location.uri)
        local range = symbol.location.range
        if not range then
            return path
                    and {
                        file = path,
                        lnum = 1,
                        col = 1,
                    }
                or nil
        end

        local row = range.start.line
        return {
            file = path,
            lnum = row + 1,
            col = position.symbol_byte_col(
                context.bufnr,
                path,
                row,
                range.start.character,
                encoding
            ) + 1,
        }
    end

    local range = symbol.selectionRange or symbol.range
    if not range then
        return nil
    end

    local row = range.start.line
    return {
        lnum = row + 1,
        col = position.symbol_byte_col(
            context.bufnr,
            nil,
            row,
            range.start.character,
            encoding
        ) + 1,
    }
end

--- Normalize LSP location/link results into file, line, and byte-column items.
---@param result table|table[]|nil LSP Location or LocationLink result.
---@param context table Conversion context with buffer number and offset encoding.
---@return table[] locations Normalized locations for navigation lists.
function M.normalize_locations(result, context)
    if not result then
        return {}
    end

    local items = tables.is_list(result) and result or { result }
    local locations = {}
    for _, item in ipairs(items) do
        local uri = item.uri or item.targetUri
        local range = item.range
            or item.targetSelectionRange
            or item.targetRange
        if uri and range and range.start then
            local path = uri_to_fname(uri)
            local row = range.start.line or 0
            if path then
                locations[#locations + 1] = {
                    file = path,
                    lnum = row + 1,
                    col = position.symbol_byte_col(
                        context.bufnr,
                        path,
                        row,
                        range.start.character or 0,
                        context.encoding
                    ) + 1,
                }
            end
        end
    end

    return locations
end

local function flatten_symbols(symbols, out, level, context)
    level = level or 1

    for _, symbol in ipairs(symbols or {}) do
        local location = symbol_range(symbol, context)
        if location then
            out[#out + 1] = {
                file = location.file,
                name = symbol.name,
                kind = symbol.kind,
                lnum = location.lnum,
                col = location.col,
                level = level,
            }
        end

        if symbol.children then
            flatten_symbols(symbol.children, out, level + 1, context)
        end
    end
end

local function normalize_document_symbols(bufnr, result, client)
    if not result then
        return {
            ok = false,
            reason = "empty_result",
            provider = "tinymist",
            client = client.name,
            symbols = {},
        }
    end

    local symbols = {}
    flatten_symbols(result, symbols, 1, {
        bufnr = bufnr,
        encoding = client.offset_encoding or "utf-16",
    })
    return {
        ok = true,
        provider = "tinymist",
        client = client.name,
        symbols = symbols,
    }
end

--- Request Tinymist document symbols for one buffer.
---@param bufnr integer Buffer whose document symbols should be requested.
---@param timeout_or_opts? integer|table Timeout in milliseconds or request options.
---@return table? pending Async request handle, or nil when no callback/client is available.
function M.document_symbols(bufnr, timeout_or_opts)
    local opts = type(timeout_or_opts) == "table" and timeout_or_opts
        or { timeout_ms = timeout_or_opts }
    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/documentSymbol",
            function()
                return {
                    textDocument = vim.lsp.util.make_text_document_params(
                        bufnr
                    ),
                }
            end,
            vim.tbl_extend("force", opts, { guard_cursor = false }),
            opts.callback,
            function(result, client)
                return normalize_document_symbols(bufnr, result, client)
            end
        )
    end

    return nil
end

--- Request Tinymist workspace symbols for a project.
---@param project table Project state used to find an attached Tinymist client.
---@param opts? table Request options; `callback` receives the normalized symbol result.
---@return table? pending Async request handle, or nil when unavailable.
function M.workspace_symbols(project, opts)
    opts = opts or {}
    local async_request = type(opts.callback) == "function"
    local client, bufnr = clients.first_project_client(project, {
        request = "async",
    })
    if
        not client
        or not clients.supports_method(client, "workspace/symbol", bufnr)
    then
        return nil
    end

    if not async_request then
        return nil
    end

    return request_async.request(
        bufnr,
        "workspace/symbol",
        function()
            return {
                query = opts.query or "",
            }
        end,
        vim.tbl_extend("force", opts, { guard_cursor = false }),
        opts.callback,
        function(result, request_client)
            local symbols = {}
            flatten_symbols(result or {}, symbols, 1, {
                bufnr = bufnr,
                encoding = request_client.offset_encoding or "utf-16",
            })
            return {
                ok = true,
                provider = "tinymist",
                client = request_client.name,
                symbols = symbols,
            }
        end
    )
end

return M
