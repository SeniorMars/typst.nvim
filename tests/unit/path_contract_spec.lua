local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local path = require("typst.core.path")

local base = typst_test_cache_path("path-contract-base")
vim.fn.mkdir(base, "p")

local joined = path.join(base, "/absolute-tail")
assert(
    joined == base .. path.path_sep() .. "/absolute-tail",
    "path.join should document trusted string-concat behavior"
)

local checked = assert(path.join_checked(base, "chapter.typ"))
assert(
    path.path_within(checked, base),
    "join_checked relative child should stay inside base"
)
assert(
    checked:match("chapter%.typ$"),
    "join_checked should keep relative child name"
)

local empty_tail = assert(path.join_checked(base))
assert(
    path.same_path(empty_tail, base),
    "join_checked with no child components should normalize the base path"
)

local absolute_path, absolute_err = path.join_checked(base, "/tmp/main.typ")
assert(absolute_path == nil, "join_checked should reject absolute Unix child")
assert(
    absolute_err and absolute_err.reason == "absolute_component",
    "absolute child should report absolute_component"
)

local windows_drive_path, windows_drive_err =
    path.join_checked(base, "C:/tmp/main.typ")
assert(
    windows_drive_path == nil,
    "join_checked should reject Windows drive child"
)
assert(
    windows_drive_err and windows_drive_err.reason == "absolute_component",
    "Windows drive child should report absolute_component"
)

local windows_drive_relative_path, windows_drive_relative_err =
    path.join_checked(base, "C:tmp/main.typ")
assert(
    windows_drive_relative_path == nil,
    "join_checked should reject Windows drive-relative child"
)
assert(
    windows_drive_relative_err
        and windows_drive_relative_err.reason == "absolute_component",
    "Windows drive-relative child should report absolute_component"
)

local unc_path, unc_err = path.join_checked(base, "\\\\server\\share\\main.typ")
assert(unc_path == nil, "join_checked should reject UNC child")
assert(
    unc_err and unc_err.reason == "absolute_component",
    "UNC child should report absolute_component"
)

local parent_path, parent_err = path.join_checked(base, "chapters/../main.typ")
assert(parent_path == nil, "join_checked should reject parent traversal")
assert(
    parent_err and parent_err.reason == "parent_component",
    "parent traversal should report parent_component"
)

if vim.fn.has("win32") == 0 then
    local uv = vim.uv or vim.loop
    local real_base = typst_test_cache_path("path-contract-real")
    local link_base = typst_test_cache_path("path-contract-link")
    vim.fn.delete(real_base, "rf")
    vim.fn.delete(link_base, "rf")
    vim.fn.mkdir(real_base, "p")
    local symlink_ok = pcall(uv.fs_symlink, real_base, link_base)
    if symlink_ok and vim.fn.isdirectory(link_base) == 1 then
        local symlink_child = assert(path.join_checked(link_base, "child.typ"))
        assert(
            path.path_within(symlink_child, link_base),
            "join_checked should preserve containment for symlink bases"
        )
    end
end

vim.cmd("qa!")
