local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local heavy_modules = {
    "typst.health",
    "typst.preview.native",
    "typst.preview.native.browser",
    "typst.preview.native.server",
    "typst.integrations.tinymist.features",
    "typst.integrations.tinymist.requests",
    "typst.package.registry_scan",
    "typst.viewer",
    "typst.viewer.api",
}

for _, module_name in ipairs(heavy_modules) do
    package.loaded[module_name] = nil
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("startup-lazy-output"),
    completion = {
        package_cache_prewarm = false,
    },
    preview = {
        follow_buffer = false,
    },
})

for _, module_name in ipairs(heavy_modules) do
    assert(
        package.loaded[module_name] == nil,
        ("setup should not eagerly load %s"):format(module_name)
    )
end

typst.reset({ force = true })
vim.cmd("qa!")
