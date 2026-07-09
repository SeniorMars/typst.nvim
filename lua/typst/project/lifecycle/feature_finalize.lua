local core_lifecycle = require("typst.core.lifecycle")
local deferred_import_scan =
    require("typst.project.lifecycle.deferred_import_scan")
local integration_service = require("typst.project.services.integrations")

local M = {}

---Finalize editor/integration state after a buffer belongs to a project.
---@param bufnr integer Buffer whose project attachment was committed.
---@param state table Project state now owning the buffer.
---@param candidate? table Project resolution candidate used for deferred scans.
---@param opts? table Finalization options.
function M.attached_buffer(bufnr, state, candidate, opts)
    opts = opts or {}
    if opts.reapply_features == true and vim.api.nvim_buf_is_valid(bufnr) then
        core_lifecycle.apply_buffer_features_all_windows(bufnr, {
            force = true,
        })
    end

    local tinymist = require("typst.integrations.tinymist")
    local tinymist_ok, tinymist_reason = tinymist.ensure(bufnr, state)
    integration_service.set_tinymist(state, {
        ok = tinymist_ok == true,
        reason = tinymist_reason,
        bufnr = bufnr,
        mode = tinymist.lsp_mode(),
    })

    if opts.schedule_deferred ~= false then
        deferred_import_scan.schedule(bufnr, state, candidate)
    end
end

return M
