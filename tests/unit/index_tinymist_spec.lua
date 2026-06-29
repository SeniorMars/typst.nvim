local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("index-tinymist-output"),
})

local workdir = typst_test_cache_path("index-tinymist")
vim.fn.mkdir(workdir, "p")
local main = workdir .. "/main.typ"
vim.fn.writefile({
    "= Local Heading",
    "semantic-card()",
    "workspace-card()",
}, main)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)

local requests = 0
local requested_methods = {}
local fake_client = {
    id = 88,
    name = "tinymist",
    offset_encoding = "utf-16",
    request = function(_, method, params, callback, request_bufnr)
        requests = requests + 1
        requested_methods[method] = (requested_methods[method] or 0) + 1
        assert(
            request_bufnr == bufnr,
            "Tinymist index requests should use the project buffer"
        )

        if method == "textDocument/documentSymbol" then
            assert(params.textDocument, "document symbol params missing")
            callback(nil, {
                {
                    name = "Semantic Heading",
                    kind = vim.lsp.protocol.SymbolKind.String,
                    selectionRange = {
                        start = { line = 1, character = 0 },
                        ["end"] = { line = 1, character = 15 },
                    },
                },
                {
                    name = "semantic-card",
                    kind = vim.lsp.protocol.SymbolKind.Function,
                    selectionRange = {
                        start = { line = 1, character = 0 },
                        ["end"] = { line = 1, character = 13 },
                    },
                },
            })
            return true, requests
        end

        if method == "workspace/symbol" then
            local workspace_name = params.query == "changed" and "changed-card"
                or "workspace-card"
            callback(nil, {
                {
                    name = workspace_name,
                    kind = vim.lsp.protocol.SymbolKind.Function,
                    location = {
                        uri = vim.uri_from_fname(main),
                        range = {
                            start = { line = 2, character = 0 },
                            ["end"] = { line = 2, character = 14 },
                        },
                    },
                },
            })
            return true, requests
        end

        if method == "textDocument/references" then
            assert(
                params.context and params.context.includeDeclaration == false,
                "semantic index references should not duplicate declarations"
            )
            callback(nil, {
                {
                    uri = vim.uri_from_fname(main),
                    range = {
                        start = {
                            line = params.position.line,
                            character = 0,
                        },
                        ["end"] = {
                            line = params.position.line,
                            character = 14,
                        },
                    },
                },
            })
            return true, requests
        end

        error("unexpected Tinymist method: " .. tostring(method))
    end,
    request_sync = function()
        requests = requests + 1
        error("synchronous index collection should not request Tinymist")
    end,
}

function fake_client:supports_method()
    return true
end

local old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == bufnr then
        return { fake_client }
    end
    return {}
end

local function has_source(items, source_kind)
    for _, item in ipairs(items or {}) do
        if item.source_kind == source_kind then
            return true
        end
    end
    return false
end

local function has_item(items, source_kind, name)
    for _, item in ipairs(items or {}) do
        if item.source_kind == source_kind and item.name == name then
            return true
        end
    end
    return false
end

local syntactic = typst.index.collect({ project = project })
assert(
    requests == 0,
    "default project index collection should not request Tinymist"
)
assert(
    not has_source(syntactic.headings, "tinymist"),
    "default index should not include Tinymist headings"
)
assert(
    not has_source(syntactic.definitions, "tinymist"),
    "default index should not include Tinymist definitions"
)

local semantic =
    typst.index.collect({ project = project, include_tinymist = true })
assert(
    requests == 0,
    "include_tinymist should not perform synchronous Tinymist requests"
)
assert(
    not has_source(semantic.headings, "tinymist"),
    "synchronous index should not include Tinymist headings"
)
assert(
    not has_source(semantic.definitions, "tinymist"),
    "synchronous index should not include Tinymist definitions"
)
assert(
    not has_source(semantic.references, "tinymist"),
    "synchronous index should not include Tinymist references"
)

assert(
    vim.wait(500, function()
        return (requested_methods["textDocument/references"] or 0) == 2
    end),
    "include_tinymist should populate Tinymist symbol and reference caches asynchronously"
)
assert(
    requested_methods["textDocument/documentSymbol"] == 1,
    "semantic index should request document symbols asynchronously"
)
assert(
    requested_methods["workspace/symbol"] == 1,
    "semantic index should request workspace symbols asynchronously"
)

local semantic_cached =
    typst.index.collect({ project = project, include_tinymist = true })
assert(
    has_source(semantic_cached.headings, "tinymist"),
    "cached Tinymist document symbols should add semantic headings"
)
assert(
    has_source(semantic_cached.definitions, "tinymist"),
    "cached Tinymist symbols should add semantic definitions"
)
assert(
    has_source(semantic_cached.references, "tinymist"),
    "cached Tinymist references should add semantic references"
)

local workspace_requests_before_generation = requested_methods["workspace/symbol"]
    or 0
local reference_requests_before_generation = requested_methods["textDocument/references"]
    or 0
assert(
    typst.index.mark_dirty(project, "semantic generation test"),
    "semantic generation test should invalidate the project index"
)
local generation_changed = typst.index.collect({
    project = project,
    include_tinymist = true,
})
assert(
    not has_item(generation_changed.definitions, "tinymist", "workspace-card"),
    "changed index generation should not merge stale workspace definitions"
)
assert(
    not has_item(generation_changed.references, "tinymist", "workspace-card"),
    "changed index generation should not merge stale workspace references"
)
assert(
    not has_item(generation_changed.references, "tinymist", "semantic-card"),
    "changed index generation should not merge stale document references"
)
assert(
    vim.wait(500, function()
        return (requested_methods["workspace/symbol"] or 0)
                == workspace_requests_before_generation + 1
            and (requested_methods["textDocument/references"] or 0)
                >= reference_requests_before_generation + 2
    end),
    "changed index generation should refresh Tinymist semantic references"
)
local generation_changed_cached = typst.index.collect({
    project = project,
    include_tinymist = true,
})
assert(
    has_item(
        generation_changed_cached.definitions,
        "tinymist",
        "workspace-card"
    ),
    "fresh workspace cache for the new generation should merge definitions"
)
assert(
    has_item(generation_changed_cached.references, "tinymist", "workspace-card"),
    "fresh workspace cache for the new generation should merge references"
)
assert(
    has_item(generation_changed_cached.references, "tinymist", "semantic-card"),
    "fresh document cache for the new generation should merge references"
)

local workspace_requests_before_query = requested_methods["workspace/symbol"]
    or 0
local reference_requests_before_query = requested_methods["textDocument/references"]
    or 0
local changed_query = typst.index.collect({
    project = project,
    include_tinymist = true,
    tinymist_workspace_query = "changed",
})
assert(
    not has_item(changed_query.definitions, "tinymist", "workspace-card"),
    "changed workspace symbol query should not merge stale workspace definitions"
)
assert(
    not has_item(changed_query.references, "tinymist", "workspace-card"),
    "changed workspace symbol query should not merge stale workspace references"
)
assert(
    vim.wait(500, function()
        return (requested_methods["workspace/symbol"] or 0)
                == workspace_requests_before_query + 1
            and (requested_methods["textDocument/references"] or 0)
                >= reference_requests_before_query + 1
    end),
    "changed workspace symbol query should refresh Tinymist workspace cache"
)

local changed_query_cached = typst.index.collect({
    project = project,
    include_tinymist = true,
    tinymist_workspace_query = "changed",
})
assert(
    has_item(changed_query_cached.definitions, "tinymist", "changed-card"),
    "refreshed workspace symbol query should merge new workspace definitions"
)
assert(
    has_item(changed_query_cached.references, "tinymist", "changed-card"),
    "refreshed workspace symbol query should merge new workspace references"
)

local requests_before_syntactic = requests
local cached_syntactic = typst.index.collect({ project = project })
assert(
    requests == requests_before_syntactic,
    "semantic collection should not poison the default aggregate cache"
)
assert(
    not has_source(cached_syntactic.definitions, "tinymist"),
    "default cached index should remain syntactic"
)

vim.lsp.get_clients = old_get_clients

vim.cmd("qa!")
