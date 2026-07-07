local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local toc = require("typst.navigation.toc")
local typst = require("typst")
local util = require("typst.core.util")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-tinymist-output"),
})
local tinymist = require("typst.integrations.tinymist")
local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
vim.cmd.edit(main)
local main_bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(main_bufnr, 0, 1, false, { "αβ = Main" })
local chapter_bufnr = vim.fn.bufadd(chapter)
vim.fn.bufload(chapter_bufnr)
vim.api.nvim_buf_set_lines(chapter_bufnr, 0, 1, false, { "αβ == Chapter" })
local project = typst.project.set_main(main)

local original_get_clients = vim.lsp.get_clients
local request_count = 0
local requested_bufnr = nil

local fake_client = {
    id = 77,
    name = "tinymist",
    offset_encoding = "utf-16",
    rpc = {
        is_closing = function()
            return true
        end,
    },
    stop = function() end,
}

function fake_client:supports_method()
    return true
end

rawset(
    fake_client,
    "request",
    function(_, method, params, callback, request_bufnr)
        assert(
            method == "textDocument/documentSymbol",
            "unexpected Tinymist method: " .. method
        )
        assert(
            params.textDocument,
            "document symbols should include document params"
        )
        request_count = request_count + 1
        requested_bufnr = request_bufnr
        callback(nil, {
            {
                name = "Main",
                kind = vim.lsp.protocol.SymbolKind.String,
                selectionRange = {
                    start = { line = 0, character = 3 },
                    ["end"] = { line = 0, character = 9 },
                },
                children = {
                    {
                        name = "Nested",
                        kind = vim.lsp.protocol.SymbolKind.String,
                        selectionRange = {
                            start = { line = 2, character = 0 },
                            ["end"] = { line = 2, character = 8 },
                        },
                    },
                },
            },
        })
        return true, request_count
    end
)

rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr and opts.bufnr ~= main_bufnr then
        return {}
    end
    return { fake_client }
end)

local symbols_result
local pending = tinymist.document_symbols(main_bufnr, {
    callback = function(result)
        symbols_result = result
    end,
})
assert(pending and pending.pending, "Tinymist symbols should be async")
assert(symbols_result and symbols_result.ok, "Tinymist symbols should resolve")
assert(
    requested_bufnr == main_bufnr,
    "Tinymist symbols should request the target buffer"
)
assert(
    #symbols_result.symbols == 2,
    "Tinymist document symbols should flatten nested children"
)
assert(
    symbols_result.symbols[1].name == "Main",
    "Tinymist document symbols should preserve top-level symbol"
)
assert(
    symbols_result.symbols[1].col == 6,
    "Tinymist DocumentSymbol column should decode UTF-16 to byte column"
)
assert(
    symbols_result.symbols[2].name == "Nested"
        and symbols_result.symbols[2].level == 2,
    "Tinymist document symbols should preserve child level"
)

local before_toc_requests = request_count
local items = toc.collect(project, { layers = false })
assert(
    request_count == before_toc_requests,
    "synchronous TOC collection should not request Tinymist symbols"
)
assert(#items >= 1, "synchronous TOC should fall back to indexed headings")

rawset(fake_client, "request", function(_, method, _, callback, request_bufnr)
    assert(
        method == "textDocument/documentSymbol",
        "unexpected Tinymist method: " .. method
    )
    request_count = request_count + 1
    requested_bufnr = request_bufnr
    callback(nil, {
        {
            name = "Chapter",
            kind = vim.lsp.protocol.SymbolKind.String,
            location = {
                uri = vim.uri_from_fname(chapter),
                range = {
                    start = { line = 0, character = 3 },
                    ["end"] = { line = 0, character = 13 },
                },
            },
        },
    })
    return true, request_count
end)

symbols_result = nil
tinymist.document_symbols(main_bufnr, {
    callback = function(result)
        symbols_result = result
    end,
})
assert(
    symbols_result and symbols_result.symbols[1].name == "Chapter",
    "Tinymist SymbolInformation response should produce document symbols"
)
assert(
    symbols_result.symbols[1].file == chapter,
    "Tinymist SymbolInformation URI should become symbol file"
)
assert(
    symbols_result.symbols[1].col == 6,
    "Tinymist SymbolInformation column should decode UTF-16 to byte column"
)

local uv = vim.uv or vim.loop
local symlink_dir = typst_test_cache_path("toc-tinymist-symlink-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(symlink_dir, "p")
local canonical_main = symlink_dir .. "/canonical.typ"
local linked_main = symlink_dir .. "/linked.typ"
vim.fn.writefile({ "αβ = Linked" }, canonical_main)
if uv.fs_symlink(canonical_main, linked_main) then
    vim.cmd.edit(vim.fn.fnameescape(linked_main))
    local linked_bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(linked_bufnr, 0, 1, false, { "αβ = Linked" })
    local symlink_project = {
        key = "toc-tinymist-symlink",
        root = symlink_dir,
        main = util.normalize(canonical_main),
        bufs = {},
    }
    rawset(vim.lsp, "get_clients", function(opts)
        if opts and opts.bufnr == linked_bufnr then
            return { fake_client }
        end
        return {}
    end)

    assert(
        tinymist.available_for_project(symlink_project) == true,
        "Tinymist availability should use equivalent loaded main buffers"
    )
end

vim.lsp.get_clients = original_get_clients

vim.cmd("qa!")
