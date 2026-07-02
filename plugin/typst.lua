-- plugin/ files can be sourced more than once in a session, especially during
-- tests or manual :runtime reloads. Keep setup one-shot so user commands and
-- global autocmds do not get registered repeatedly.
if vim.g.loaded_typst_nvim == 1 then
    return
end

vim.g.loaded_typst_nvim = 1

if
    vim.g.typst_nvim_no_auto_setup == 1
    or vim.g.typst_nvim_no_auto_setup == true
then
    return
end

require("typst").setup()
