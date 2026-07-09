local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local typst = require("typst")
local util = require("typst.core.util")

local fixture_root = typst_test_cache_path("main-callback-invalid-return")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root .. "/chapters", "p")
local main = fixture_root .. "/main.typ"
local chapter = fixture_root .. "/chapters/intro.typ"
vim.fn.writefile({ "= Main", '#include "chapters/intro.typ"' }, main)
vim.fn.writefile({ "= Chapter" }, chapter)

local function setup_with_main(main_config)
    typst.reset({ force = true })
    log.clear()
    typst.setup({
        root = fixture_root,
        main = main_config,
        output_dir = typst_test_cache_path("main-callback-invalid-output"),
        project = {
            import_scan = false,
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(chapter))
    vim.bo.filetype = "typst"
    return assert(
        typst.project.get(0),
        "invalid main callback result should not crash project attach"
    )
end

local direct = setup_with_main(function()
    return true
end)
local direct_resolution = direct.resolutions[vim.api.nvim_get_current_buf()]
assert(
    direct.main == util.normalize(main),
    "invalid direct main callback result should fall back to main.typ"
)
assert(
    direct_resolution.main_source == "root heuristic main.typ",
    "direct invalid callback should record fallback main source"
)

local saw_direct_warning = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "ignored invalid Typst path callback result"
        and entry.fields
        and entry.fields.source == "config.main callback"
        and entry.fields.result_type == "boolean"
    then
        saw_direct_warning = true
        break
    end
end
assert(saw_direct_warning, "invalid direct main callback result should log")

local mapped = setup_with_main({
    [fixture_root] = function()
        return 0
    end,
})
local mapped_resolution = mapped.resolutions[vim.api.nvim_get_current_buf()]
assert(
    mapped.main == util.normalize(main),
    "invalid table main callback result should fall back to main.typ"
)
assert(
    mapped_resolution.main_source == "root heuristic main.typ",
    "table invalid callback should record fallback main source"
)

local saw_mapped_warning = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "ignored invalid Typst path callback result"
        and entry.fields
        and entry.fields.source == "config.main table callback"
        and entry.fields.result_type == "number"
    then
        saw_mapped_warning = true
        break
    end
end
assert(saw_mapped_warning, "invalid table main callback result should log")

typst.reset({ force = true })
vim.cmd("qa!")
