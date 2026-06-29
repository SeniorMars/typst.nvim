local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local registry = require("typst.project")
local typst = require("typst")
typst.reset()

local executable = helpers.fake_typst_sleep(root)

typst.setup({
    root = root,
    executable = executable,
    output_dir = typst_test_cache_path("hidden-lifecycle-output"),
    compile = {
        deps = false,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local bufnr = vim.api.nvim_get_current_buf()

vim.cmd("hide enew")
assert(
    project.bufs[bufnr],
    "plain BufHidden should keep retained hidden buffers attached"
)
assert(
    registry.all()[project.key] == project,
    "plain BufHidden should keep retained hidden projects registered"
)

vim.cmd("buffer " .. bufnr)
typst.project.detach(bufnr)
assert(
    registry.all()[project.key] == nil,
    "manual detach should prune the retained hidden project"
)

vim.cmd.edit(main)
local unload_project = typst.project.set_main(main)
local unload_bufnr = vim.api.nvim_get_current_buf()
vim.bo[unload_bufnr].bufhidden = "unload"

local compile_callback_called = false
local handle = typst.compiler.compile({ notify = false }, function()
    compile_callback_called = true
end)

assert(
    typst_test_compiler(unload_project).process == handle,
    "compile process should be active before BufHidden unload cleanup"
)
assert(
    unload_project.bufs[unload_bufnr],
    "buffer should be attached before BufHidden unload cleanup"
)

vim.cmd("hide enew")

assert(
    not unload_project.bufs[unload_bufnr],
    "BufHidden unload should detach buffer from project membership"
)

assert(
    vim.wait(10000, function()
        return typst_test_compiler(unload_project).process == nil
            and registry.all()[unload_project.key] == nil
            and handle:is_closing()
    end, 20),
    "BufHidden unload should stop active compiles and prune the empty project"
)

vim.wait(200, function()
    return compile_callback_called
end, 20)
assert(
    not compile_callback_called,
    "stale hidden-buffer compile result should not call public callback"
)

vim.cmd("qa!")
