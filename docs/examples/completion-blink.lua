-- blink.cmp adapter.
local typst = require("typst")

typst.setup({})

-- Inline module shim for a single-file config example. In a full config, place
-- this table in its own Lua module and use that module name below.
package.loaded["typst_blink_source"] = {
    new = function()
        return typst.completion.blink_source({
            include_tinymist = true,
        })
    end,
}

require("blink.cmp").setup({
    sources = {
        default = { "lsp", "path", "typst" },
        providers = {
            typst = {
                name = "typst.nvim",
                module = "typst_blink_source",
            },
        },
    },
})
