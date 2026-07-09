local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    preview = {
        follow_buffer = true,
    },
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(
    bufnr,
    typst_test_cache_path("preview-follow-settle/main.typ")
)
vim.bo[bufnr].filetype = "typst"

local original_context = package.loaded["typst.project.context"]
local observed_policy = nil
package.loaded["typst.project.context"] = {
    resolve = function(_, policy)
        observed_policy = policy
        return nil
    end,
}

local ok, err = xpcall(function()
    require("typst.preview.follow_buffer").on_buffer(bufnr)
end, debug.traceback)

package.loaded["typst.project.context"] = original_context
typst.reset({ force = true })
vim.api.nvim_buf_delete(bufnr, { force = true })

if not ok then
    error(err)
end

assert(
    observed_policy and observed_policy.create == false,
    "follow_buffer should perform a passive project lookup"
)
assert(
    observed_policy.settle_pending == false,
    "follow_buffer should not accept import-scan suggestions from BufEnter"
)

vim.cmd("qa!")
