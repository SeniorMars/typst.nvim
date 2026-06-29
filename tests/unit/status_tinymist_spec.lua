local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local tinymist = require("typst.integrations.tinymist")
local typst = require("typst")
local util = require("typst.core.util")
local uv = vim.uv or vim.loop

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("status-tinymist-output"),
    diagnostics = {
        source = "fallback",
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
local bufnr = vim.api.nvim_get_current_buf()

local client = {
    name = "tinymist",
}

local old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr and opts.bufnr ~= bufnr then
        return {}
    end
    return { client }
end

local snapshot = typst.ui.status()
assert(
    snapshot.tinymist_lsp_backend == "nvim_lsp"
        and snapshot.tinymist_lsp_mode == "auto"
        and snapshot.tinymist_lsp_attached == true,
    "status() should expose project Tinymist Neovim LSP attachment"
)
assert(
    snapshot.compiler_diagnostics == "fallback_suppressed_by_tinymist",
    "status() should expose compiler diagnostics suppression by Tinymist"
)

local captured = {}
local original_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end

local ok, err = pcall(function()
    typst.ui.info()
end)

vim.api.nvim_echo = original_echo
vim.lsp.get_clients = old_get_clients
assert(ok, err)

local text = table.concat(captured, "\n")
assert(
    text:find("tinymist nvim%-lsp:%s+auto attached"),
    "TypstInfo should show project Tinymist Neovim LSP attachment"
)
assert(
    text:find("compiler diagnostics:%s+fallback suppressed by Tinymist/Coc"),
    "TypstInfo should explain compiler diagnostics suppression by Tinymist/Coc"
)

local symlink_root = vim.fn.tempname()
vim.fn.mkdir(symlink_root, "p")
local canonical_main = symlink_root .. "/canonical.typ"
local linked_main = symlink_root .. "/linked.typ"
vim.fn.writefile({ "#let linked-symbol = none" }, canonical_main)
local symlink_ok = uv.fs_symlink(canonical_main, linked_main)
if symlink_ok then
    vim.cmd.edit(vim.fn.fnameescape(linked_main))
    local linked_bufnr = vim.api.nvim_get_current_buf()
    local workspace_request_bufnr = nil
    local workspace_client = {
        name = "tinymist",
        offset_encoding = "utf-16",
    }

    function workspace_client:supports_method(method)
        return method == "workspace/symbol"
    end

    workspace_client.request = function(_, method, _, callback, request_bufnr)
        assert(
            method == "workspace/symbol",
            "workspace symbols should request Tinymist workspace symbols"
        )
        workspace_request_bufnr = request_bufnr
        callback(nil, {
            {
                name = "linked-symbol",
                kind = vim.lsp.protocol.SymbolKind.Function,
                location = {
                    uri = vim.uri_from_fname(canonical_main),
                    range = {
                        start = { line = 0, character = 5 },
                        ["end"] = { line = 0, character = 18 },
                    },
                },
            },
        })
        return true, 1
    end

    old_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
        if opts and opts.bufnr == linked_bufnr then
            return { workspace_client }
        end
        return {}
    end

    local project = {
        main = util.normalize(canonical_main),
        bufs = {},
    }
    assert(
        tinymist.available_for_project(project) == true,
        "project Tinymist availability should find an equivalent loaded main buffer"
    )
    local symbols_result
    local pending = tinymist.workspace_symbols(project, {
        callback = function(result)
            symbols_result = result
        end,
    })
    vim.lsp.get_clients = old_get_clients

    assert(pending and pending.pending, "workspace symbols should be async")
    assert(
        workspace_request_bufnr == linked_bufnr,
        "workspace symbols should use the equivalent loaded main buffer"
    )
    assert(
        symbols_result
            and symbols_result.symbols
            and symbols_result.symbols[1]
            and symbols_result.symbols[1].name == "linked-symbol",
        "workspace symbols should be returned"
    )
end

typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "off",
        },
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
vim.lsp.get_clients = function()
    return { client }
end

local disabled_project = typst.project.get(0)
assert(
    tinymist.available_for_project(disabled_project) == false,
    "disabled Tinymist LSP integration should not query Neovim LSP clients"
)
local disabled_snapshot = typst.ui.status()
vim.lsp.get_clients = old_get_clients
assert(
    disabled_snapshot.tinymist_lsp_enabled == false
        and disabled_snapshot.tinymist_lsp_attached == false,
    "status() should expose disabled Tinymist Neovim LSP integration"
)

vim.cmd("qa!")
