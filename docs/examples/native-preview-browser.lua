-- Native typst.nvim browser preview using SVG exports and source maps.
require("typst").setup({
    preview = {
        provider = "native",
        native = "browser",
        follow_buffer = true,
        source_maps = {
            provider = "typst-query",
        },
        browser = {
            performance = "fast",
            export = {
                mode = "profile",
                profile = "preview_svg",
            },
        },
    },
    exports = {
        profiles = {
            preview_svg = {
                output_format = "svg",
            },
        },
    },
})
