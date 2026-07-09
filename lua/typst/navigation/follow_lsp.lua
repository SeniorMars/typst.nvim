local tinymist = require("typst.integrations.tinymist")
local coordinates = require("typst.core.coordinates")

local M = {}

local function project_for_buffer(bufnr)
    local ok, project = pcall(require, "typst.project")
    if ok and type(project.get) == "function" then
        return project.get(bufnr)
    end
end

local function normalize_location(value, encoding)
    local location = vim.islist(value) and value[1] or value
    if not location then
        return nil
    end

    local uri = location.uri or location.targetUri
    local range = location.range
        or location.targetSelectionRange
        or location.targetRange
    if not uri or not range or not range.start then
        return nil
    end

    local path = vim.uri_to_fname(uri)
    local row = range.start.line or 0
    return {
        kind = "definition",
        path = path,
        lnum = row + 1,
        col = coordinates.file_lsp_character_to_byte_col(
            path,
            row,
            range.start.character or 0,
            encoding
        ) + 1,
        provider = "tinymist",
        semantic = true,
    }
end

function M.can_request_async(bufnr, opts)
    opts = opts or {}
    if opts.semantic == false then
        return false
    end

    return tinymist.select_client({
        bufnr = bufnr,
        project = project_for_buffer(bufnr),
        method = "textDocument/definition",
        request = "async",
    }).ok == true
end

function M.definition(bufnr, opts)
    if opts.semantic == false then
        return nil
    end

    local result, client = tinymist.definition(bufnr, {
        timeout_ms = opts.timeout_ms,
        pos = opts.pos,
        position = opts.position,
    })
    return normalize_location(
        result,
        client and client.offset_encoding or "utf-16"
    )
end

function M.definition_async(bufnr, opts, callback)
    opts = opts or {}
    if opts.semantic == false then
        callback(nil, {
            ok = false,
            reason = "disabled",
            provider = "tinymist",
        })
        return {
            ok = false,
            reason = "disabled",
            provider = "tinymist",
        }
    end

    return tinymist.definition(
        bufnr,
        vim.tbl_extend("force", opts, {
            callback = function(result, client)
                if not result.ok then
                    callback(nil, result)
                    return
                end

                callback(
                    normalize_location(
                        result.definition or result.result,
                        client and client.offset_encoding or "utf-16"
                    ),
                    result
                )
            end,
        })
    )
end

return M
