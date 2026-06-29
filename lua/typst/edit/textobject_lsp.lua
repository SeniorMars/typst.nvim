local tinymist = require("typst.integrations.tinymist")
local coordinates = require("typst.core.coordinates")
local request_async = require("typst.integrations.tinymist.async")
local util = require("typst.edit.textobject_util")

local M = {}

-- LSP selectionRange is used as a best-effort textobject fallback. Convert at
-- the boundary because internal edit ranges are zero-based byte offsets, while
-- Tinymist speaks LSP client offsets.

local function client_supports_selection_range(client, bufnr)
    if type(client.supports_method) ~= "function" then
        return true
    end

    local ok, supported = pcall(
        client.supports_method,
        client,
        "textDocument/selectionRange",
        bufnr
    )
    if ok then
        return supported
    end

    ok, supported =
        pcall(client.supports_method, client, "textDocument/selectionRange")
    return ok and supported or false
end

local function lsp_position(bufnr, pos, encoding)
    local row, col = util.cursor_position(pos, bufnr)
    if not row or not col then
        return nil
    end
    return {
        line = row,
        character = coordinates.byte_col_to_lsp_character(
            bufnr,
            row,
            col,
            encoding
        ),
    }
end

local function lsp_range_to_range(bufnr, lsp_range, encoding)
    if not lsp_range or not lsp_range.start or not lsp_range["end"] then
        return nil
    end

    local start_row = lsp_range.start.line
    local end_row = lsp_range["end"].line
    local range = {
        start_row = start_row,
        start_col = coordinates.buffer_lsp_character_to_byte_col(
            bufnr,
            start_row,
            lsp_range.start.character,
            encoding
        ),
        end_row = end_row,
        end_col = coordinates.buffer_lsp_character_to_byte_col(
            bufnr,
            end_row,
            lsp_range["end"].character,
            encoding
        ),
    }

    if
        range.end_row < range.start_row
        or (
            range.end_row == range.start_row
            and range.end_col <= range.start_col
        )
    then
        return nil
    end

    return range
end

local function range_contains(outer, inner)
    return (
        outer.start_row < inner.start_row
        or (
            outer.start_row == inner.start_row
            and outer.start_col <= inner.start_col
        )
    )
        and (
            outer.end_row > inner.end_row
            or (
                outer.end_row == inner.end_row
                and outer.end_col >= inner.end_col
            )
        )
end

local function selection_range_for_part(bufnr, selection, part, encoding)
    local inner =
        lsp_range_to_range(bufnr, selection and selection.range, encoding)
    if part ~= "outer" then
        return inner
    end

    local parent = selection and selection.parent
    while parent do
        -- For "outer", pick the first strictly larger parent range. Some LSP
        -- servers repeat the child range in the parent chain.
        local parent_range = lsp_range_to_range(bufnr, parent.range, encoding)
        if
            parent_range
            and inner
            and range_contains(parent_range, inner)
            and util.range_size(parent_range) > util.range_size(inner)
        then
            return parent_range
        end
        parent = parent.parent
    end

    return inner
end

function M.selection_range(bufnr, part, opts)
    opts = opts or {}

    if type(opts.callback) == "function" then
        return request_async.request(
            bufnr,
            "textDocument/selectionRange",
            function(client)
                if not client_supports_selection_range(client, bufnr) then
                    return nil
                end
                local encoding = client.offset_encoding or "utf-16"
                local position = opts.position
                    or lsp_position(bufnr, opts.pos, encoding)
                if not position then
                    return nil
                end
                return {
                    textDocument = vim.lsp.util.make_text_document_params(
                        bufnr
                    ),
                    positions = { position },
                }
            end,
            opts,
            opts.callback,
            function(result, client)
                local range = nil
                if type(result) == "table" and result[1] then
                    range = selection_range_for_part(
                        bufnr,
                        result[1],
                        part,
                        client.offset_encoding or "utf-16"
                    )
                end
                return {
                    ok = range ~= nil,
                    provider = "tinymist",
                    client = client.name,
                    range = range,
                    ranges = result or {},
                    reason = range and nil or "no_range",
                }
            end
        )
    end

    return nil
end

return M
