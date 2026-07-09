local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local preview_export = require("typst.preview.export")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    preview = {
        export = {
            mode = "compile",
        },
    },
})

local project = {
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
}

local profile_missing = preview_export.resolve(project, "viewer", nil, {
    mode = "profile",
})
assert(
    profile_missing.ok == false
        and profile_missing.reason == "missing_preview_profile",
    "mode=profile should be authoritative even without a profile field"
)

local provider_missing = preview_export.resolve(project, "viewer", nil, {
    mode = "provider",
})
assert(
    provider_missing.ok == false
        and provider_missing.reason == "missing_preview_provider",
    "mode=provider should be authoritative even without a provider field"
)

local compile_missing = preview_export.resolve(project, "viewer", nil, {
    mode = "compile",
})
assert(
    compile_missing.ok == false
        and compile_missing.reason == "missing_compiler_output",
    "mode=compile should continue to use compiler output"
)

local document_mode = preview_export.effective("viewer", {
    mode = "document",
})
assert(
    document_mode.mode == "compile",
    "preview mode=document should not override preview export mode"
)

typst.reset({ force = true })
vim.cmd("qa!")
