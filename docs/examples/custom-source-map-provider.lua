-- Minimal source-map provider for native browser clicks. This toy provider maps
-- every browser click to the start of the main Typst file.
local typst = require("typst")

typst.providers.register("source_map", "main-start", {
    capabilities = function()
        return {
            browser_click = true,
        }
    end,

    browser_inverse = function(project, _request)
        return {
            ok = true,
            path = project.main,
            line = 1,
            column = 1,
        }
    end,
})

typst.setup({
    preview = {
        provider = "native",
        native = "browser",
        source_maps = {
            provider = "main-start",
        },
    },
})
