-- plugin/ files can be sourced more than once in a session, especially during
-- tests or manual :runtime reloads. Keep setup one-shot so user commands and
-- global autocmds do not get registered repeatedly.
if vim.g.loaded_typst_nvim == 1 then
    return
end

vim.g.loaded_typst_nvim = 1

require("typst").setup()
