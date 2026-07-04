local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local main = root .. "/tests/fixtures/basic/main.typ"

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-error-missing-output"),
    preview = {
        native = "viewer",
        export = {
            mode = "compile",
        },
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
local missing_output = typst.viewer.preview({ notify = false })
assert(
    type(missing_output) == "table"
        and missing_output.ok == false
        and missing_output.reason == "missing_compiler_output",
    "preview compile-mode missing output should be structured"
)
assert(
    missing_output.message:find(":TypstCompile", 1, true)
        and missing_output.message:find("preview.export.mode", 1, true),
    "missing output error should tell users how to recover"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-error-invalid-native"),
    preview = {
        native = "viewer",
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
local invalid_native = typst.viewer.preview({
    notify = false,
    native = "invalid-target",
})
assert(
    type(invalid_native) == "table"
        and invalid_native.ok == false
        and invalid_native.reason == "invalid_preview_native",
    "invalid native preview config should be structured"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-error-unavailable"),
    preview = {
        provider = "typst-preview.nvim",
        fallback = "error",
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
local unavailable = typst.viewer.preview({ notify = false })
assert(
    type(unavailable) == "table"
        and unavailable.ok == false
        and unavailable.reason == "preview_backend_unavailable",
    "unavailable preview backend should be structured"
)

vim.cmd("qa!")
