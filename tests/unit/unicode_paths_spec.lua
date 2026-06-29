local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local project_root = typst_test_cache_path("unicode paths/자료/δοκιμή")
local output_dir = typst_test_cache_path("unicode output/épreuves")
local main = project_root .. "/main α.typ"

assert(
    vim.fn.mkdir(project_root, "p") == 1
        or vim.fn.isdirectory(project_root) == 1,
    "failed to create Unicode project root"
)
assert(
    vim.fn.mkdir(output_dir, "p") == 1 or vim.fn.isdirectory(output_dir) == 1,
    "failed to create Unicode output dir"
)
assert(vim.fn.writefile({
    "= Unicode paths",
    "",
    "Typst can compile from 자료/δοκιμή and write to épreuves.",
}, main) == 0, "failed to write Unicode Typst fixture")

typst.setup({
    root = project_root,
    output_dir = output_dir,
    allow_external_output = true,
})

vim.cmd.edit(vim.fn.fnameescape(main))
local project = typst.project.set_main(main)
assert(
    project.root == project_root,
    "project root should preserve Unicode path bytes"
)
assert(project.main == main, "project main should preserve Unicode path bytes")
assert(
    typst_test_compiler(project).output:find(output_dir, 1, true) == 1,
    "project output should use the Unicode output directory"
)

if vim.fn.executable("typst") == 1 then
    local compile_result = nil
    local handle = typst.compiler.compile({ notify = false }, function(result)
        compile_result = result
    end)
    assert(handle, "Unicode-path compile should return a process handle")
    assert(
        vim.wait(5000, function()
            return compile_result ~= nil
        end, 20),
        "Unicode-path compile did not finish"
    )
    assert(
        compile_result.code == 0,
        compile_result.stderr or "Unicode-path compile failed"
    )
    assert(
        vim.fn.filereadable(typst_test_compiler(project).output) == 1,
        "Unicode-path compile should write the output artifact"
    )
end

vim.cmd("qa!")
