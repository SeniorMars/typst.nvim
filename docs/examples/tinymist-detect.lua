-- Reuse an existing Neovim LSP Tinymist client started by another plugin.
require("typst").setup({
    integrations = {
        tinymist = {
            lsp = "detect",
            client_names = { "tinymist" },
        },
    },
})
