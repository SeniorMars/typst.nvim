-- Let coc.nvim/coc-tinymist own the LSP session.
-- Configure tinymist.serverPath and tinymist.serverArgs in Coc settings.
require("typst").setup({
    integrations = {
        tinymist = {
            lsp = "off",
        },
    },
    diagnostics = {
        source = "fallback",
    },
})
