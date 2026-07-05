local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("output-name-output"),
    output_name = "custom-main",
    output_format = "pdf",
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

assert(
    typst_test_compiler(project).output
        == typst_test_cache_path("output-name-output/custom-main.pdf"),
    ("unexpected configured output path: %s"):format(
        typst_test_compiler(project).output
    )
)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed with configured output_name")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish with configured output_name"
)

assert(
    vim.fn.filereadable(typst_test_compiler(project).output) == 1,
    "configured output_name file should exist after compile"
)
assert(
    typst_test_compiler(project).last_command[#typst_test_compiler(project).last_command]
        == typst_test_compiler(project).output,
    "compile command should use configured output_name"
)
assert(
    typst.ui.status().output_name == "custom-main.pdf",
    "status should expose configured output filename"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("output-name-output"),
    output_name = "nested/custom-main",
})
vim.cmd.edit(main)
local bad_name_ok, bad_name_err = pcall(function()
    typst.project.set_main(main)
end)
assert(not bad_name_ok, "output_name with path separators should fail closed")
assert(
    tostring(bad_name_err):match("output_name must be a basename"),
    tostring(bad_name_err)
)

typst.reset()
local external_dir = vim.fn.tempname() .. "-typst-nvim-output"
typst.setup({
    root = root,
    output_dir = external_dir,
})
vim.cmd.edit(main)
local external_ok, external_err = pcall(function()
    typst.project.set_main(main)
end)
assert(
    not external_ok,
    "external output_dir should require explicit allow_external_output"
)
assert(
    tostring(external_err):match("allow_external_output"),
    tostring(external_err)
)

typst.reset()
typst.setup({
    root = root,
    output_dir = external_dir,
    allow_external_output = true,
})
vim.cmd.edit(main)
local external_project = typst.project.set_main(main)
assert(
    typst_test_compiler(external_project).output:find(external_dir, 1, true)
        == 1,
    "allow_external_output should permit explicit external output_dir"
)

vim.cmd("qa!")
