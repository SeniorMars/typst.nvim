local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local tinymist = require("typst.integrations.tinymist")

typst.reset()
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
    integrations = {
        tinymist = {
            lsp = "start",
        },
    },
})

local fixture_root = typst_test_cache_path("tinymist-status")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(main)
vim.bo.filetype = "typst"

local original_ensure = tinymist.ensure
local original_mode = tinymist.lsp_mode
tinymist.ensure = function(bufnr)
    assert(bufnr == vim.api.nvim_get_current_buf(), "ensure should see buffer")
    return false, "missing_executable"
end
tinymist.lsp_mode = function()
    return "start"
end

local project = typst.project.attach(0)

tinymist.ensure = original_ensure
tinymist.lsp_mode = original_mode

assert(project ~= nil, "Tinymist ensure failure should not fail attach")
assert(
    project.tinymist_ensure
        and project.tinymist_ensure.reason == "missing_executable",
    "project snapshot should expose the last Tinymist ensure reason"
)

local status =
    require("typst.ui.status").snapshot(vim.api.nvim_get_current_buf())
assert(
    status.tinymist_ensure
        and status.tinymist_ensure.reason == "missing_executable",
    "status snapshot should expose the last Tinymist ensure reason"
)

vim.cmd("qa!")
