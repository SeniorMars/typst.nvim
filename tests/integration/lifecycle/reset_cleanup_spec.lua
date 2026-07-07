local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local registry = require("typst.project")
local project_store = require("typst.project.store")
local toc = require("typst.navigation.toc")
local typst = require("typst")

typst.reset()

local preview_stopped = 0
local preview_stop_project = nil

typst.setup({
    root = root,
    executable = helpers.fake_typst_sleep(root),
    output_dir = typst_test_cache_path("reset-cleanup-output"),
    compile = {
        deps = false,
    },
    preview = {
        open = function()
            return true
        end,
        stop = function(project)
            preview_stopped = preview_stopped + 1
            preview_stop_project = project
            return true
        end,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
project = assert(
    typst.project.attach(0),
    "reset fixture should attach the current buffer"
)
local bufnr = vim.api.nvim_get_current_buf()
local buffer_group = ("typst_nvim_buf_%d"):format(bufnr)
assert(
    vim.fn.exists("#" .. buffer_group) == 1,
    "reset fixture should create buffer-local autocmds"
)

local compile_callback_called = false
local handle = typst.compiler.compile({}, function()
    compile_callback_called = true
end)
assert(
    typst_test_compiler(project).process == handle,
    "reset fixture should have an active compile"
)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "reset fixture should open a preview"
)
assert(
    typst_test_preview(project).active == true,
    "reset fixture should track an active preview"
)

vim.wo.conceallevel = 0
typst.conceal.disable(bufnr)
assert(
    vim.b[bufnr].typst_conceal_enabled == false,
    "reset fixture should set a conceal override"
)
typst.conceal.enable(bufnr)
assert(
    vim.wo.conceallevel == 2,
    "reset fixture should apply conceallevel before reset"
)

typst.navigation.toc({ open = true })
assert(toc.is_open(project), "reset fixture should open a project TOC window")

typst.reset()

assert(
    vim.tbl_count(project_store.all()) == 0,
    "typst.reset should clear registered projects"
)
assert(
    preview_stopped == 1,
    "typst.reset should stop active previews before clearing state"
)
assert(
    preview_stop_project and preview_stop_project.key == project.key,
    "typst.reset preview cleanup should receive the active project"
)
assert(
    typst_test_preview(project).active == false,
    "typst.reset should clear active preview state"
)
assert(not toc.is_open(project), "typst.reset should close project TOC windows")
assert(
    typst_test_compiler(project).process == nil,
    "typst.reset should clear active compile handles"
)
assert(
    typst_test_compiler(project).status == "idle",
    "typst.reset should return active compile projects to idle"
)
assert(not typst.is_setup(), "typst.reset should return setup state to false")
assert(
    vim.fn.exists("#" .. buffer_group) == 0,
    "typst.reset should delete buffer-local autocmd groups"
)
assert(
    vim.b[bufnr].typst_conceal_enabled == nil,
    "typst.reset should clear conceal buffer overrides"
)
assert(
    vim.wo.conceallevel == 0,
    "typst.reset should restore window conceallevel"
)

assert(
    vim.wait(10000, function()
        return handle:is_closing()
    end, 20),
    "typst.reset should terminate active compile processes"
)

vim.wait(200, function()
    return compile_callback_called
end, 20)
assert(
    not compile_callback_called,
    "typst.reset should stale active compile callbacks"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("reset-cleanup-output"),
    preview = {
        open = function()
            return true
        end,
    },
})
vim.cmd.edit(main)
local unstoppable_project = typst.project.set_main(main)
local live_unstoppable_project = assert(
    project_store.get(unstoppable_project.key),
    "live unstoppable project"
)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "unstoppable reset fixture should open a preview"
)
assert(
    typst_test_preview(live_unstoppable_project).active == true,
    "unstoppable reset fixture should track active preview"
)

local unstoppable_reset = typst.reset()
assert(
    unstoppable_reset and unstoppable_reset.ok == false,
    "typst.reset should report unconfirmed preview shutdown"
)
assert(
    typst_test_preview(live_unstoppable_project).active == true,
    "typst.reset should retain unstoppable preview state"
)
assert(
    project_store.all()[unstoppable_project.key]
        and project_store.all()[unstoppable_project.key].key
            == unstoppable_project.key,
    "typst.reset should retain unstoppable preview projects"
)
typst.reset({ force = true })
vim.cmd("qa!")
