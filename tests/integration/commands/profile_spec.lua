local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_name = "default-name",
    output_dir = typst_test_cache_path("profile-default"),
    compile = {
        profiles = {
            draft = {
                output_dir = typst_test_cache_path("profile-draft"),
                output_name = "draft-output.pdf",
                output_format = "pdf",
            },
        },
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({ profile = "draft" }, function(result)
    assert(result.code == 0, "profile compile failed")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst profile compile did not finish"
)

assert(
    typst_test_compiler(project).last_profile == "draft",
    "project should remember the last compile profile"
)
assert(
    typst.ui.status().profile == "draft",
    "status should expose the last compile profile"
)
assert(
    typst.ui.statusline() == "Typst:success main.typ [draft]",
    "statusline should show the active profile"
)
assert(
    typst.ui.statusline({ profile = false }) == "Typst:success main.typ",
    "statusline should allow hiding the active profile"
)
assert(
    typst_test_compiler(project).output
        == typst_test_cache_path("profile-draft/draft-output.pdf"),
    typst_test_compiler(project).output
)
assert(
    vim.fn.filereadable(typst_test_compiler(project).output) == 1,
    ("missing profile output %s"):format(typst_test_compiler(project).output)
)
assert(
    typst_test_compiler(project).last_command[#typst_test_compiler(project).last_command]
        == typst_test_compiler(project).output,
    "profile output should be passed to typst"
)
assert(
    require("typst.config").get().compile.open == false,
    "profile compile should not mutate global config"
)
assert(
    require("typst.config").get().output_name == "default-name",
    "profile compile should not mutate base output name"
)

local ok, err = pcall(function()
    typst.compiler.compile({ profile = "missing" })
end)
assert(not ok, "unknown compile profile should fail")
assert(tostring(err):match("unknown compile profile"), tostring(err))

vim.cmd("qa!")
