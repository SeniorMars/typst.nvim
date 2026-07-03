-- nvim-cmp adapter.
local cmp = require("cmp")
local typst = require("typst")

typst.setup({})

cmp.register_source(
    "typst",
    typst.completion.cmp_source({
        include_tinymist = true,
    })
)

cmp.setup.filetype("typst", {
    sources = cmp.config.sources({
        { name = "typst" },
        { name = "nvim_lsp" },
        { name = "path" },
        { name = "buffer" },
    }),
})
