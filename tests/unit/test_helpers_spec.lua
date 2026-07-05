local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_helper = require("tests.helpers.project")

local opened = project_helper.open_typst_project({
    name = "helper-generated-root",
    files = {
        ["main.typ"] = "= Helper root",
    },
})
assert(
    opened.project.root == opened.root,
    "helper-created projects should set up typst.nvim with the generated root"
)
assert(
    opened.project.main == opened.main,
    "helper-created projects should attach the generated main"
)

vim.cmd("qa!")
