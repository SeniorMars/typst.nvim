local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local fragment_helpers = require("typst.compiler.fragment_helpers")
local typst = require("typst")
typst.reset()
local project_root = typst_test_cache_path("clean-project")
vim.fn.mkdir(project_root, "p")
local fragment_root = project_root .. "/clean-fragments"
typst.setup({
    root = project_root,
    output_dir = typst_test_cache_path("clean-output"),
    compile = {
        fragments = {
            source_dir = fragment_root .. "/custom-fragments",
            templates = {
                custom = {
                    source_dir = fragment_root .. "/template-fragments",
                },
            },
        },
    },
})

local main = project_root .. "/main.typ"
assert(
    vim.fn.writefile({ "= Clean", "temporary cleanup test" }, main) == 0,
    "failed to create cleanup project main"
)
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local clean_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstOutputCleaned",
    callback = function(args)
        clean_event = args.data
    end,
})

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before clean test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before clean test"
)

assert(
    vim.fn.filereadable(typst_test_compiler(project).output) == 1,
    "compiled output should exist before clean"
)

local configured_fragment_dir = fragment_root .. "/custom-fragments"
assert(
    vim.fn.mkdir(configured_fragment_dir, "p") == 1
        or vim.fn.isdirectory(configured_fragment_dir) == 1,
    "failed to create configured fragment dir"
)
fragment_helpers.mark_owned_source_dir(configured_fragment_dir)
local configured_fragment_file = configured_fragment_dir
    .. "/phase1-configured-clean.typ"
assert(
    vim.fn.writefile(
        { "configured temporary fragment" },
        configured_fragment_file
    ) == 0,
    "failed to create configured temporary artifact"
)
local template_fragment_dir = fragment_root .. "/template-fragments"
assert(
    vim.fn.mkdir(template_fragment_dir, "p") == 1
        or vim.fn.isdirectory(template_fragment_dir) == 1,
    "failed to create template fragment dir"
)
fragment_helpers.mark_owned_source_dir(template_fragment_dir)
local template_fragment_file = template_fragment_dir
    .. "/phase1-template-clean.typ"
assert(
    vim.fn.writefile({ "template temporary fragment" }, template_fragment_file)
        == 0,
    "failed to create template temporary artifact"
)

local result = typst.viewer.clean()
assert(
    not result.deleted,
    "plain clean should not report generated output deletion"
)
assert(
    not result.output_deleted,
    "plain clean should not delete generated outputs"
)
assert(
    not result.missing,
    "plain clean should not report missing output after compile"
)
assert(
    result.output == typst_test_compiler(project).output,
    "clean should report the project output path"
)
assert(
    result.temporary_deleted >= 2,
    "plain clean should report temporary artifact deletion"
)
assert(
    vim.fn.filereadable(typst_test_compiler(project).output) == 1,
    "plain clean should preserve the generated output"
)
assert(
    vim.fn.isdirectory(configured_fragment_dir) == 0,
    "plain clean should delete configured fragment source artifacts"
)
assert(
    vim.fn.isdirectory(template_fragment_dir) == 0,
    "plain clean should delete template fragment source artifacts"
)
assert(clean_event, "TypstOutputCleaned event was not emitted")
assert(clean_event.key == project.key, "clean event had wrong project key")
assert(
    clean_event.output == typst_test_compiler(project).output,
    "clean event had wrong output"
)
assert(
    clean_event.output_deleted == false,
    "plain clean event should not report output deletion"
)
assert(
    type(clean_event.temporary) == "table",
    "clean event should include temporary artifacts"
)

local output = typst_test_compiler(project).output
assert(vim.fn.writefile({
    "user-modified compile output",
    "must not be deleted without force",
}, output) == 0, "failed to modify compile output before forced clean")

local skipped = typst.viewer.clean({ all = true })
assert(
    not skipped.deleted,
    "full clean should not delete changed compile output without force"
)
assert(
    skipped.skipped_output and skipped.reason == "changed_output",
    "full clean should report changed owned compile output as skipped"
)
assert(
    skipped.output == output,
    "skipped clean should report the project output path"
)
assert(
    vim.fn.filereadable(output) == 1,
    "full clean should preserve changed compile output without force"
)

local full = typst.viewer.clean({ all = true, force = true })
assert(
    full.deleted,
    "full clean should report that it deleted the generated output"
)
assert(
    full.output_deleted,
    "full clean should report generated output deletion"
)
assert(
    not full.missing,
    "full clean should not report missing output after deletion"
)
assert(
    full.output == output,
    "full clean should report the project output path"
)
assert(
    vim.fn.filereadable(output) == 0,
    "forced full clean should delete the changed generated output"
)
assert(
    clean_event.output_deleted == true,
    "full clean event should report output deletion"
)

local missing = typst.viewer.clean({ all = true })
assert(
    not missing.deleted,
    "full clean should not report deletion for a missing output"
)
assert(
    missing.missing,
    "full clean should report missing output on repeated clean"
)
assert(
    missing.output == output,
    "missing clean should report the same output path"
)

vim.cmd("qa!")
