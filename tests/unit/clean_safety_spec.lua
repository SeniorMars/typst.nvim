local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local fragment_helpers = require("typst.compiler.fragment_helpers")
local typst = require("typst")
local util = require("typst.core.util")

local function mkdir(path)
    assert(
        vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1,
        ("failed to create %s"):format(path)
    )
end

local function write(path, lines)
    assert(
        vim.fn.writefile(lines, path) == 0,
        ("failed to write %s"):format(path)
    )
end

local function setup_project(source_dir)
    local project_root = vim.fn.tempname()
    mkdir(project_root)
    local main = project_root .. "/main.typ"
    write(main, { "= Clean safety" })

    typst.reset()
    typst.setup({
        root = project_root,
        compile = {
            fragments = {
                source_dir = source_dir,
            },
        },
    })
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    return project_root, project
end

local dangerous_root, dangerous_project = setup_project(".")
local root_marker = dangerous_root .. "/keep.txt"
write(root_marker, { "must survive" })

local root_clean =
    typst.viewer.clean({ bufnr = vim.api.nvim_get_current_buf() })
assert(
    root_clean.temporary_skipped_count >= 1,
    "clean should report skipped unsafe fragment source directories"
)
assert(
    vim.fn.isdirectory(dangerous_root) == 1,
    "fragment cleanup must not delete the project root"
)
assert(
    vim.fn.filereadable(root_marker) == 1,
    "fragment cleanup must preserve project-root files"
)
assert(
    root_clean.temporary_skipped[1].reason == "unsafe_fragment_source_dir",
    "project-root fragment cleanup should be refused as unsafe"
)
assert(
    util.same_path(dangerous_project.root, dangerous_root),
    "project setup sanity check"
)

local user_root = setup_project("fragments")
local user_dir = user_root .. "/fragments"
mkdir(user_dir)
local user_file = user_dir .. "/left-alone.typ"
write(user_file, { "temporary but not owned" })

local user_clean =
    typst.viewer.clean({ bufnr = vim.api.nvim_get_current_buf() })
assert(
    user_clean.temporary_skipped_count >= 1,
    "clean should skip user fragment directories without ownership proof"
)
assert(
    vim.fn.filereadable(user_file) == 1,
    "clean should preserve unowned configured fragment source files"
)

local owned_root = setup_project("fragments-owned")
local owned_dir = owned_root .. "/fragments-owned"
mkdir(owned_dir)
local owned_file = owned_dir .. "/owned.typ"
write(owned_file, { "temporary and owned" })
fragment_helpers.mark_owned_source_dir(owned_dir)

local owned_clean =
    typst.viewer.clean({ bufnr = vim.api.nvim_get_current_buf() })
assert(
    owned_clean.temporary_deleted >= 1,
    "clean should delete sentinel-owned fragment source directories"
)
assert(
    vim.fn.isdirectory(owned_dir) == 0,
    "sentinel-owned fragment source directory should be removed"
)

typst.reset()
vim.cmd("qa!")
