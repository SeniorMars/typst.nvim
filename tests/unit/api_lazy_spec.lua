local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

for module_name in pairs(package.loaded) do
    if module_name == "typst" or module_name:find("^typst%.") then
        package.loaded[module_name] = nil
    end
end
vim.g.loaded_typst_nvim = 1

local typst = require("typst")

for _, module_name in ipairs({
    "typst.package",
    "typst.bibliography",
    "typst.completion",
    "typst.conceal",
    "typst.edit.folds",
    "typst.edit.indent",
    "typst.edit.match_highlight",
    "typst.workflows.render",
    "typst.workflows.artifacts",
    "typst.workflows.eval",
    "typst.workflows.development",
    "typst.integrations.typst_preview",
    "typst.integrations.semantic",
    "typst.navigation.toc",
    "typst.syntax",
    "typst.compiler.api",
    "typst.viewer.api",
    "typst.internal.commands_api",
}) do
    assert(
        package.loaded[module_name] == nil,
        ("require('typst') should not eagerly load %s"):format(module_name)
    )
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-lazy-output"),
    completion = {
        package_cache_prewarm = false,
    },
})

for _, module_name in ipairs({
    "typst.package",
    "typst.bibliography",
    "typst.completion",
    "typst.conceal",
    "typst.edit.folds",
    "typst.edit.indent",
    "typst.edit.match_highlight",
    "typst.workflows.render",
    "typst.workflows.artifacts",
    "typst.workflows.eval",
    "typst.workflows.development",
    "typst.integrations.typst_preview",
    "typst.integrations.semantic",
    "typst.navigation.toc",
    "typst.syntax",
    "typst.compiler.api",
    "typst.viewer.api",
    "typst.internal.commands_api",
}) do
    assert(
        package.loaded[module_name] == nil,
        ("setup() should not eagerly load %s"):format(module_name)
    )
end

typst.reset()

for _, module_name in ipairs({
    "typst.package",
    "typst.bibliography",
    "typst.completion",
    "typst.conceal",
    "typst.edit.folds",
    "typst.edit.indent",
    "typst.edit.match_highlight",
    "typst.workflows.render",
    "typst.workflows.artifacts",
    "typst.workflows.eval",
    "typst.workflows.development",
    "typst.integrations.typst_preview",
    "typst.integrations.semantic",
    "typst.navigation.toc",
    "typst.syntax",
    "typst.compiler.api",
    "typst.viewer.api",
    "typst.internal.commands_api",
}) do
    assert(
        package.loaded[module_name] == nil,
        ("reset() should not eagerly load %s"):format(module_name)
    )
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-lazy-output"),
    completion = {
        package_cache_prewarm = false,
    },
})

assert(
    type(typst.package.info) == "function",
    "lazy package namespace should still expose functions"
)
assert(
    package.loaded["typst.package"] == nil,
    "reading lazy package functions should not load package module"
)
typst.package.cached_packages({ roots = {}, max = 1 })
assert(
    package.loaded["typst.package"] ~= nil,
    "calling lazy package functions should load package module"
)

vim.cmd("qa!")
