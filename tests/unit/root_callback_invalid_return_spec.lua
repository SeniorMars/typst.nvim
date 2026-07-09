local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local typst = require("typst")
local util = require("typst.core.util")

local fixture_root = typst_test_cache_path("root-callback-invalid-return")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root .. "/.git", "p")
vim.fn.mkdir(fixture_root .. "/chapters", "p")
local main = fixture_root .. "/main.typ"
local chapter = fixture_root .. "/chapters/intro.typ"
vim.fn.writefile({ "= Main", '#include "chapters/intro.typ"' }, main)
vim.fn.writefile({ "= Chapter" }, chapter)

typst.reset({ force = true })
log.clear()
typst.setup({
    root = function()
        return { fixture_root }
    end,
    output_dir = typst_test_cache_path("root-callback-invalid-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.edit(vim.fn.fnameescape(chapter))
vim.bo.filetype = "typst"
local project = assert(
    typst.project.get(0),
    "invalid root callback result should not crash project attach"
)
local resolution = project.resolutions[vim.api.nvim_get_current_buf()]

assert(
    project.root == util.normalize(fixture_root),
    "invalid root callback result should fall back to root markers"
)
assert(
    project.main == util.normalize(main),
    "invalid root callback result should still resolve root main.typ"
)
assert(
    resolution.root_source == "root marker .git",
    "resolution should record the fallback root source"
)

local saw_warning = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "ignored invalid Typst path callback result"
        and entry.fields
        and entry.fields.source == "config.root callback"
        and entry.fields.result_type == "table"
    then
        saw_warning = true
        break
    end
end
assert(saw_warning, "invalid root callback result should be logged")

typst.reset({ force = true })
vim.cmd("qa!")
