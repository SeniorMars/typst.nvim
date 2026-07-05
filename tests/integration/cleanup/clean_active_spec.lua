local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")
typst.reset()

local executable = helpers.fake_typst_sleep(root)

typst.setup({
    root = root,
    executable = executable,
    output_dir = typst_test_cache_path("clean-active-output"),
    compile = {
        deps = false,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local handle = typst.compiler.compile()
assert(
    typst_test_compiler(project).process == handle,
    "compile process should be active before clean refusal"
)

local ok, err = pcall(function()
    typst.viewer.clean()
end)
assert(not ok, "clean should refuse while a one-shot compile is active")
assert(tostring(err):match("stop the active Typst compiler"), tostring(err))
assert(
    typst_test_compiler(project).process == handle,
    "failed clean should leave the active compile tracked"
)

typst.compiler.stop()
assert(
    vim.wait(10000, function()
        return typst_test_compiler(project).process == nil
            and handle:is_closing()
    end, 20),
    "active compile did not stop after clean refusal test"
)

vim.cmd("qa!")
