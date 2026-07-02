local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")
local util = require("typst.core.util")

local original_cwd = vim.fn.getcwd()
local base = helpers.cache_path("main-mapping-cwd")
local other_cwd = helpers.cache_path("main-mapping-other-cwd")
vim.fn.delete(base, "rf")
vim.fn.delete(other_cwd, "rf")
vim.fn.mkdir(base .. "/docs", "p")
vim.fn.mkdir(other_cwd, "p")
vim.fn.writefile(
    { "= Main", '#include "chapter.typ"' },
    base .. "/docs/main.typ"
)
vim.fn.writefile({ "= Chapter" }, base .. "/docs/chapter.typ")

local ok, err = pcall(function()
    vim.cmd("cd " .. vim.fn.fnameescape(base))
    typst.reset({ force = true })
    typst.setup({
        root_markers = {},
        main = {
            docs = "main.typ",
        },
        project = {
            import_scan = false,
        },
    })

    vim.cmd.edit(vim.fn.fnameescape(base .. "/docs/chapter.typ"))
    vim.bo.filetype = "typst"
    local bufnr = vim.api.nvim_get_current_buf()
    local project = assert(
        typst.project.attach(bufnr),
        "buffer should attach through relative main mapping"
    )
    assert(
        project.root == util.normalize(base .. "/docs"),
        "relative main mapping root should be normalized at setup"
    )
    assert(
        project.main == util.normalize(base .. "/docs/main.typ"),
        "relative main mapping should select the configured main"
    )

    vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
    local resolved = typst.project.attach(bufnr)
    assert(
        resolved.root == project.root,
        ":cd should not change normalized main mapping root"
    )
    assert(
        resolved.main == project.main,
        ":cd should not change normalized main mapping main"
    )
end)

vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
assert(ok, err)
