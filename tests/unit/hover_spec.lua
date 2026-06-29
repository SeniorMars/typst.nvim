local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("hover-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.attach(0)
local bufnr = vim.api.nvim_get_current_buf()

assert(
    vim.fn.maparg("<Plug>(typst-hover)", "n") ~= "",
    "typst-hover plug mapping should be registered"
)
assert(
    vim.fn.maparg("K", "n") == "",
    "typst.nvim should leave K unmapped by default"
)

local original_get_clients = vim.lsp.get_clients
local original_hover = vim.lsp.buf.hover
local hover_calls = 0
local expected_hover_bufnr = nil

vim.lsp.buf.hover = function()
    if expected_hover_bufnr then
        assert(
            vim.api.nvim_get_current_buf() == expected_hover_bufnr,
            "native LSP hover should run in the requested buffer"
        )
    end
    hover_calls = hover_calls + 1
end

vim.lsp.get_clients = function(opts)
    assert(
        opts and opts.bufnr == bufnr,
        "hover should query clients for the requested buffer"
    )
    return {}
end
assert(
    typst.navigation.hover({ bufnr = bufnr }) == false,
    "hover should report false without attached LSP clients"
)
assert(
    hover_calls == 0,
    "hover should not call native LSP hover without a client"
)

vim.lsp.get_clients = function()
    return {
        {
            name = "tinymist",
            supports_method = function(_, method)
                return method == "textDocument/hover"
            end,
        },
    }
end
assert(
    typst.navigation.hover({ bufnr = bufnr }) == true,
    "hover should delegate to native LSP hover"
)
assert(hover_calls == 1, "hover should call native LSP hover exactly once")

local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(other)
expected_hover_bufnr = bufnr
assert(
    typst.navigation.hover({ bufnr = bufnr }) == true,
    "hover should support noncurrent requested buffers"
)
assert(
    vim.api.nvim_get_current_buf() == other,
    "hover should restore the previously current buffer"
)
assert(hover_calls == 2, "noncurrent-buffer hover should call native LSP hover")
vim.api.nvim_set_current_buf(bufnr)
expected_hover_bufnr = nil

vim.lsp.get_clients = function()
    return {
        {
            name = "no-hover",
            supports_method = function()
                return false
            end,
        },
    }
end
assert(
    typst.navigation.hover({ bufnr = bufnr }) == false,
    "hover should ignore clients without hover support"
)
assert(
    hover_calls == 2,
    "hover should not call native LSP hover for unsupported clients"
)

vim.lsp.get_clients = original_get_clients
vim.lsp.buf.hover = original_hover

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("hover-output"),
    mappings = {
        hover = "K",
    },
})
vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.attach(0)
assert(
    vim.fn.maparg("K", "n") == "<Plug>(typst-hover)",
    "mappings.hover should opt into K hover mapping"
)

vim.cmd("qa!")
