local coordinates = require("typst.core.coordinates")

local M = {}
for name, value in pairs(coordinates) do
    M[name] = value
end

--- Build LSP formatting options from a buffer's indentation settings.
---@param bufnr integer Buffer whose local options should be read.
---@return table options LSP FormattingOptions for Tinymist requests.
function M.formatting_options(bufnr)
    local shiftwidth = vim.bo[bufnr].shiftwidth
    local tabstop = vim.bo[bufnr].tabstop

    return {
        tabSize = shiftwidth > 0 and shiftwidth or tabstop,
        insertSpaces = vim.bo[bufnr].expandtab,
    }
end

return M
