local util = require("typst.core.util")

local M = {}

local cache = {}

function M.for_glyph(glyph)
    local cached = cache[glyph]
    if cached then
        return cached
    end

    local scalar_count = util.scalar_count(glyph)
    local result = {
        codepoints = util.codepoints(glyph),
        scalar_count = scalar_count,
        grapheme_count = util.grapheme_count(glyph),
        display_width = vim.fn.strdisplaywidth(glyph),
        nvim_conceal_safe = scalar_count == 1,
    }
    cache[glyph] = result
    return result
end

function M.reset()
    cache = {}
end

return M
