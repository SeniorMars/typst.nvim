local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local graph_sources = require("typst.project.graph.sources")
local project_model = require("typst.project.model")
local util = require("typst.core.util")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("scratch-rebuild-output"),
})
local function contains(items, predicate)
    for _, item in ipairs(items or {}) do
        if predicate(item) then
            return true
        end
    end
    return false
end

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "= Scratch Rebuild <scratch:rebuild>",
    "Unsaved text should survive graph rebuild.",
})
local project =
    assert(typst.project.attach(bufnr), "scratch buffer should attach")
local resolution =
    assert(project.resolutions[bufnr], "scratch resolution should be stored")
assert(resolution.scratch == true, "buffer should resolve as scratch")

local scratch_path = util.normalize(resolution.buffer)
assert(
    graph_sources.get(project)[scratch_path],
    "scratch path should be present before graph rebuild"
)

project_model.rebuild_files(project)
assert(
    graph_sources.get(project)[scratch_path],
    "scratch path should survive graph rebuild"
)

local collected = typst.index.collect({ project = project })
assert(
    contains(collected.headings, function(item)
        return item.title == "Scratch Rebuild"
    end),
    "scratch index should still read unsaved buffer text after rebuild"
)

vim.cmd("qa!")
