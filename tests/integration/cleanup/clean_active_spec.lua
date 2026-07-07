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

local result = typst.viewer.clean()
assert(
    type(result) == "table"
        and result.ok == false
        and result.reason == "active_compiler",
    "clean should return active_compiler while a one-shot compile is active"
)
assert(result.message:match("active Typst compiler"), tostring(result.message))
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
