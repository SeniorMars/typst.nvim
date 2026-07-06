local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_store = require("typst.project.store")

typst.reset()
typst.setup({ completion = { package_cache_prewarm = false } })

local bufnr = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "markdown"

local opened, open_err = typst.project.edit_main({
    bufnr = bufnr,
    notify = false,
})
assert(opened == nil, "edit_main outside Typst project should not return path")
assert(
    type(open_err) == "table" and open_err.reason == "no_project",
    "edit_main should return a structured no_project error"
)

local cwd, cd_err = typst.project.cd({
    bufnr = bufnr,
    notify = false,
})
assert(cwd == nil, "cd outside Typst project should not return root")
assert(
    type(cd_err) == "table" and cd_err.reason == "no_project",
    "cd should return a structured no_project error"
)

local fixture_root = typst_test_cache_path("project-api-unattached")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
local chapter = fixture_root .. "/chapter.typ"
vim.fn.writefile({ "main words" }, main)
vim.fn.writefile({ "chapter words" }, chapter)
vim.fn.writefile({ "main.typ" }, fixture_root .. "/.typstmain")

local typst_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(typst_bufnr, chapter)
vim.api.nvim_set_current_buf(typst_bufnr)
vim.bo[typst_bufnr].filetype = "typst"
typst.project.detach(typst_bufnr)
assert(
    project_store.project_for_buffer(typst_bufnr) == nil,
    "fixture Typst buffer should start unattached"
)

local cwd_before = vim.fn.getcwd()
local root_path, typst_cd_err = typst.project.cd({
    bufnr = typst_bufnr,
    notify = false,
})
assert(
    root_path == fixture_root,
    "cd should resolve an unattached Typst buffer"
)
assert(typst_cd_err == nil, "cd should not fail for unattached Typst buffers")
vim.cmd("lcd " .. vim.fn.fnameescape(cwd_before))

typst.project.detach(typst_bufnr)
vim.api.nvim_set_current_buf(typst_bufnr)
local opened, typst_open_err = typst.project.edit_main({
    bufnr = typst_bufnr,
    notify = false,
})
assert(opened == main, "edit_main should resolve an unattached Typst buffer")
assert(
    typst_open_err == nil,
    "edit_main should not fail for unattached Typst buffers"
)

vim.cmd("qa!")
