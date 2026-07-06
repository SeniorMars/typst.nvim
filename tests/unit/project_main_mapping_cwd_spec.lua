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
    local warnings =
        require("typst.config").last_relative_main_mapping_warnings()
    assert(
        #warnings == 1,
        "relative main mapping roots should be reported during setup"
    )
    assert(
        warnings[1].root == "docs" and warnings[1].cwd == util.normalize(base),
        "relative main mapping warning should include the setup cwd"
    )
    assert(
        warnings[1].resolved == util.normalize(base .. "/docs"),
        "relative main mapping warning should include the resolved root"
    )
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

    typst.reset({ force = true })
    vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
    typst.setup({
        root_markers = {},
        main_base_dir = util.normalize(base),
        main = {
            docs = "main.typ",
        },
        project = {
            import_scan = false,
        },
    })
    local base_warnings =
        require("typst.config").last_relative_main_mapping_warnings()
    assert(
        #base_warnings == 0,
        "explicit main_base_dir should make relative main mapping roots intentional"
    )
    vim.cmd.edit(vim.fn.fnameescape(base .. "/docs/chapter.typ"))
    vim.bo.filetype = "typst"
    local base_project = assert(
        typst.project.attach(vim.api.nvim_get_current_buf()),
        "buffer should attach through main_base_dir relative mapping"
    )
    assert(
        base_project.root == util.normalize(base .. "/docs"),
        "main_base_dir should be the base for relative main mapping roots"
    )
    assert(
        base_project.main == util.normalize(base .. "/docs/main.typ"),
        "main_base_dir relative mapping should select the configured main"
    )
end)
vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
assert(ok, err)
