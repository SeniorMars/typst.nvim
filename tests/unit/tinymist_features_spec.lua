local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-features-output"),
})
local features = require("typst.integrations.tinymist.features")
local tinymist = require("typst.integrations.tinymist")

local original_get_clients = vim.lsp.get_clients
local requests = {}

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "#let paint(color) = rect(fill: color)",
    '#paint(rgb("#ff0000"))',
})
vim.api.nvim_win_set_cursor(0, { 2, 8 })
local range = {
    start = { line = 1, character = 7 },
    ["end"] = { line = 1, character = 23 },
}

local responses = {
    ["workspace/symbol"] = {
        { name = "paint", kind = vim.lsp.protocol.SymbolKind.Function },
    },
    ["textDocument/documentHighlight"] = {
        { range = range, kind = 1 },
    },
    ["textDocument/documentLink"] = {
        { range = range, target = "file:///tmp/ref.typ" },
    },
    ["textDocument/foldingRange"] = {
        { startLine = 0, endLine = 1, kind = "region" },
    },
    ["textDocument/signatureHelp"] = {
        signatures = {
            { label = "paint(color)" },
        },
        activeSignature = 0,
        activeParameter = 0,
    },
    ["textDocument/documentColor"] = {
        {
            range = range,
            color = { red = 1, green = 0, blue = 0, alpha = 1 },
        },
    },
    ["textDocument/colorPresentation"] = {
        {
            label = "#ff0000",
            textEdit = {
                range = range,
                newText = 'rgb("#ff0000")',
            },
        },
    },
    ["textDocument/codeLens"] = {
        {
            range = range,
            command = {
                title = "Export PDF",
                command = "tinymist.exportPdf",
            },
        },
    },
    ["textDocument/selectionRange"] = {
        { range = range },
    },
    ["experimental/onEnter"] = {
        edit = {
            range = {
                start = { line = 1, character = 23 },
                ["end"] = { line = 1, character = 23 },
            },
            newText = "\n  ",
        },
    },
}

local supported = {}
for method in pairs(responses) do
    supported[method] = true
end

local fake_client = {
    id = 99001,
    name = "tinymist",
    offset_encoding = "utf-16",
    supports_method = function(_, method)
        return supported[method] == true
    end,
    request = function(_, method, params, callback, request_bufnr)
        requests[#requests + 1] = {
            method = method,
            params = params,
            bufnr = request_bufnr,
        }
        callback(nil, vim.deepcopy(responses[method]))
        return true, #requests
    end,
}

rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr == bufnr then
        return { fake_client }
    end
    return {}
end)

local function request_with_callback(fn)
    local result = nil
    local pending = fn(function(callback_result)
        result = callback_result
    end)
    assert(
        pending and pending.pending,
        "Tinymist feature should return pending"
    )
    assert(result, "Tinymist feature callback did not run")
    return result, requests[#requests]
end

local ok, err = xpcall(function()
    assert(
        features.supports(bufnr, "textDocument/documentColor"),
        "features.supports should detect attached Tinymist capabilities"
    )
    assert(
        not features.supports(bufnr, "textDocument/hover"),
        "features.supports should reject unsupported methods"
    )
    assert(
        tinymist.supports(bufnr, "textDocument/codeLens"),
        "top-level Tinymist module should expose feature supports()"
    )

    ---@type any
    local no_callback = features.document_links(bufnr, {})
    assert(
        no_callback.reason == "async_required",
        "feature helpers should require callbacks"
    )

    local generic, generic_request = request_with_callback(function(callback)
        return features.request(bufnr, "workspace/symbol", {
            params = { query = "paint" },
            guard_cursor = false,
        }, callback)
    end)
    assert(generic.ok, "generic Tinymist request should succeed")
    assert(
        generic_request.method == "workspace/symbol"
            and generic_request.params.query == "paint",
        "generic request should forward explicit params"
    )

    local highlights, highlight_request = request_with_callback(
        function(callback)
            return features.document_highlight(bufnr, {
                pos = { 1, 8 },
                callback = callback,
            })
        end
    )
    assert(
        highlights.count == 1 and highlights.highlights[1].kind == 1,
        "document_highlight should normalize highlight results"
    )
    assert(
        highlight_request.method == "textDocument/documentHighlight"
            and highlight_request.params.position.line == 1,
        "document_highlight should send position params"
    )

    local links, link_request = request_with_callback(function(callback)
        return features.document_links(bufnr, { callback = callback })
    end)
    assert(
        links.count == 1 and links.links[1].target:find("ref.typ", 1, true),
        "document_links should normalize document links"
    )
    assert(
        link_request.method == "textDocument/documentLink"
            and link_request.params.textDocument,
        "document_links should send textDocument params"
    )

    local folds = request_with_callback(function(callback)
        return features.folding_ranges(bufnr, { callback = callback })
    end)
    assert(
        folds.count == 1 and folds.ranges[1].kind == "region",
        "folding_ranges should normalize folding ranges"
    )

    local signature, signature_request = request_with_callback(
        function(callback)
            return features.signature_help(bufnr, {
                position = { line = 1, character = 8 },
                callback = callback,
            })
        end
    )
    assert(
        signature.ok
            and signature.signatures[1].label == "paint(color)"
            and signature.active_signature == 0,
        "signature_help should expose signature metadata"
    )
    assert(
        signature_request.method == "textDocument/signatureHelp",
        "signature_help should request signatureHelp"
    )

    local colors = request_with_callback(function(callback)
        return features.document_color(bufnr, { callback = callback })
    end)
    assert(
        colors.count == 1 and colors.colors[1].color.red == 1,
        "document_color should normalize colors"
    )

    ---@type any
    ---@type any
    local missing_range = nil
    ---@type any
    local missing_range_result = features.color_presentation(bufnr, {
        color = { red = 1, green = 0, blue = 0, alpha = 1 },
        callback = function(result)
            missing_range = result
        end,
    })
    assert(
        missing_range_result.reason == "missing_range"
            and missing_range.reason == "missing_range",
        "color_presentation should fail before requesting without a range"
    )

    local presentations, presentation_request = request_with_callback(
        function(callback)
            return features.color_presentation(bufnr, {
                color = { red = 1, green = 0, blue = 0, alpha = 1 },
                range = range,
                callback = callback,
            })
        end
    )
    assert(
        presentations.count == 1
            and presentations.presentations[1].label == "#ff0000",
        "color_presentation should normalize presentations"
    )
    assert(
        presentation_request.method == "textDocument/colorPresentation"
            and presentation_request.params.color.red == 1,
        "color_presentation should send color and range params"
    )

    local lenses = request_with_callback(function(callback)
        return features.code_lens(bufnr, { callback = callback })
    end)
    assert(
        lenses.count == 1
            and lenses.lenses[1].command.command == "tinymist.exportPdf",
        "code_lens should normalize code lenses"
    )

    local selections, selection_request = request_with_callback(
        function(callback)
            return features.selection_range(bufnr, {
                positions = { { line = 1, character = 8 } },
                callback = callback,
            })
        end
    )
    assert(
        selections.count == 1
            and selections.ranges[1].range.start.line == range.start.line,
        "selection_range should normalize selection ranges"
    )
    assert(
        selection_request.method == "textDocument/selectionRange"
            and #selection_request.params.positions == 1,
        "selection_range should send positions"
    )

    local on_enter, on_enter_request = request_with_callback(function(callback)
        return features.on_enter(bufnr, {
            pos = { 1, 23 },
            callback = callback,
        })
    end)
    assert(
        on_enter.ok and on_enter.edits.newText == "\n  ",
        "on_enter should expose returned edits without applying them"
    )
    assert(
        on_enter_request.method == "experimental/onEnter",
        "on_enter should request Tinymist experimental/onEnter"
    )
end, debug.traceback)

vim.lsp.get_clients = original_get_clients

if not ok then
    error(err)
end

vim.cmd("qa!")
