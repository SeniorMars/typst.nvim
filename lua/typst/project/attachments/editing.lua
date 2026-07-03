local core_lifecycle = require("typst.core.lifecycle")
local ftplugin_state = require("typst.core.ftplugin_state")

local M = {}

local function set_omnifunc_if_empty(bufnr)
    if vim.bo[bufnr].omnifunc == "" then
        ftplugin_state.set_buffer_option(
            bufnr,
            "omnifunc",
            "v:lua.typst_nvim_omnifunc"
        )
    end
end

function M.apply(bufnr)
    require("typst.edit.mappings").apply(bufnr)
    core_lifecycle.apply_buffer_features(bufnr)
    set_omnifunc_if_empty(bufnr)
end

function M.reapply(bufnr)
    ftplugin_state.restore_buffer_mappings(bufnr)
    require("typst.edit.mappings").apply(bufnr)
    core_lifecycle.apply_buffer_features_all_windows(bufnr, { force = true })
    set_omnifunc_if_empty(bufnr)
end

return M
