local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local provider = require("typst.preview.source_maps.typst_query")

typst.reset({ force = true })
provider._reset_for_tests()

local project_dir = typst_test_cache_path("source-map-cache-signature")
vim.fn.delete(project_dir, "rf")
vim.fn.mkdir(project_dir, "p")

typst.setup({
    root = project_dir,
    output_dir = project_dir,
})

local main = project_dir .. "/main.typ"
local output = project_dir .. "/main.svg"
vim.fn.writefile({ "= Before", "Body" }, main)
vim.fn.writefile({
    '<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"></svg>',
}, output)

vim.cmd.edit(vim.fn.fnameescape(main))
local project = typst.project.set_main(main)
local live = assert(require("typst.project.context").live(project))
local request = {
    output = output,
    generation = "unchanged-output",
}

local before = provider._cache_key_for_tests(live, request)
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "= After" })
local after = provider._cache_key_for_tests(live, request)

assert(
    before ~= after,
    "typst-query source-map cache key should change with source changedtick"
)

local selected = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(selected, 0, -1, false, {
    "= Selected buffer source",
})
local original_buffer_module = package.loaded["typst.core.buffer"]
local fake_buffer_module =
    vim.tbl_extend("force", original_buffer_module or {}, {
        loaded_buffer_for_path = function()
            return selected
        end,
        loaded_buffers_for_path = function()
            return { selected }
        end,
    })
package.loaded["typst.core.buffer"] = fake_buffer_module

local source_index = provider._source_index_for_tests(live)
package.loaded["typst.core.buffer"] = original_buffer_module

assert(
    source_index[1] and source_index[1].raw == "= Selected buffer source",
    "typst-query source index should read through the buffer index selection"
)

local large_project = {
    root = project_dir,
    main = project_dir .. "/large-main.typ",
    files = {},
    services = {
        index = {
            generation = 7,
            file_generation = 8,
            buffer_generation = 9,
            dependency_generation = 10,
        },
    },
}
large_project.files[large_project.main] = true
for index = 1, 500 do
    large_project.files[("%s/large/source-%03d.typ"):format(project_dir, index)] =
        true
end

local uv = vim.uv or vim.loop
local original_fs_stat = uv.fs_stat
local stat_count = 0
uv.fs_stat = function(path)
    stat_count = stat_count + 1
    return original_fs_stat(path)
end
provider._cache_key_for_tests(large_project, request)
uv.fs_stat = original_fs_stat

assert(
    stat_count <= 1,
    ("source-map cache key should use project generation instead of statting every source file; stat_count=%d"):format(
        stat_count
    )
)

vim.cmd("qa!")
