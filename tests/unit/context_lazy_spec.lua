local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lazy_modules = {
    "typst.bibliography.actions",
    "typst.package.context",
    "typst.package.info",
    "typst.package.templates",
    "typst.navigation.follow",
    "typst.ui.context_completion",
    "typst.ui.context_menu_media",
    "typst.ui.context_menu_packages",
    "typst.ui.context_menu_transforms",
    "typst.ui.context_references",
    "typst.ui.label_actions",
    "typst.metadata.symbol_search",
    "typst.ui.symbol_variants",
}

for _, name in ipairs(lazy_modules) do
    package.loaded[name] = nil
end

local context = require("typst.context")
assert(type(context.open) == "function", "typst.context should load")

for _, name in ipairs(lazy_modules) do
    assert(
        package.loaded[name] == nil,
        "requiring typst.context should not eagerly load " .. name
    )
end

vim.cmd("qa!")
