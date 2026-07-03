local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_context = require("typst.project.context")
local project_registry = require("typst.project")
local formatting = require("typst.formatting")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    project = {
        import_scan = false,
    },
})

local before = vim.tbl_count(project_registry.all())
vim.cmd.enew()
local dashboard = vim.api.nvim_get_current_buf()
vim.bo[dashboard].filetype = ""
vim.api.nvim_buf_set_lines(dashboard, 0, -1, false, { "dashboard" })

local dashboard_project = project_context.resolve({ bufnr = dashboard }, {
    create = true,
})
assert(
    dashboard_project == nil,
    "project context should not create projects from non-Typst buffers"
)
assert(
    vim.tbl_count(project_registry.all()) == before,
    "non-Typst project context lookup should not grow the registry"
)

local format_before = vim.tbl_count(project_registry.all())
local format_result = formatting.format({
    bufnr = dashboard,
    provider = "prose",
    apply = false,
})
assert(
    format_result and format_result.ok == true,
    "formatting should still support project-free non-Typst buffers"
)
assert(
    vim.tbl_count(project_registry.all()) == format_before,
    "formatting a non-Typst buffer should not create a project"
)

local fixture_root = typst_test_cache_path("project-context-create")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local typst_bufnr = vim.api.nvim_get_current_buf()

local created = project_context.resolve({ bufnr = typst_bufnr }, {
    create = true,
})
assert(created and created.main == main, "Typst buffers should create projects")

vim.cmd.enew()
vim.bo.filetype = ""
local explicit = project_context.resolve({
    bufnr = vim.api.nvim_get_current_buf(),
    project = created,
}, {
    create = true,
})
assert(
    explicit == created,
    "explicit projects should resolve from non-Typst buffers"
)

vim.cmd("qa!")
