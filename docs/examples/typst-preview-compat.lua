-- Delegate preview open/stop/source-sync commands to typst-preview.nvim.
require("typst").setup({
    preview = {
        provider = "typst-preview.nvim",
        native = "viewer",
    },
})
