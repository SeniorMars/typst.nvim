-- Conservative conceal setup. Requires a compatible Typst Tree-sitter parser.
require("typst").setup({
    conceal = {
        enabled = true,
        reveal = "node",
        reveal_insert = "node",
        renderer = {
            mode = "unicode",
        },
    },
})
