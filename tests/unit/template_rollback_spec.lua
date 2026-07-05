local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local template_files = require("typst.package.template_files")

local uv = vim.uv or vim.loop
local fixture_dir = typst_test_cache_path("template-rollback-")
    .. tostring(uv.hrtime())
local source = fixture_dir .. "/source"
local destination = fixture_dir .. "/destination"
vim.fn.mkdir(source, "p")
vim.fn.mkdir(destination, "p")
vim.fn.writefile({ "= Template" }, source .. "/main.typ")
vim.fn.writefile({ "= Existing" }, destination .. "/main.typ")

local original_rename = uv.fs_rename
local ok, err = xpcall(function()
    rawset(uv, "fs_rename", function(src, dst)
        if src:find("typst%-nvim%-staging", 1, false) then
            return nil, "forced staging move failure"
        end
        if src:find("typst%-nvim%-backup", 1, false) then
            return nil, "forced backup restore failure"
        end
        return original_rename(src, dst)
    end)

    local result = template_files.copy_dir(source, destination, {
        overwrite = true,
        source_root = source,
    })
    assert(
        result.ok == false,
        "template copy should fail when staging move fails"
    )
    assert(
        result.reason == "copy_failed",
        "template copy should report copy_failed"
    )
    assert(result.backup, "template copy failure should report the backup path")
    assert(
        result.backup_restored == false,
        "template copy failure should report failed backup restore"
    )
    assert(
        result.backup_restore_error == "forced backup restore failure",
        "template copy failure should report the backup restore error"
    )
    assert(
        vim.fn.isdirectory(result.backup) == 1,
        "failed backup restore should leave backup in place for recovery"
    )
end, debug.traceback)

uv.fs_rename = original_rename

if not ok then
    error(err)
end

if uv.fs_symlink then
    local symlink_source = fixture_dir .. "/symlink-source"
    local symlink_destination = fixture_dir .. "/symlink-destination"
    vim.fn.mkdir(symlink_source, "p")
    vim.fn.writefile({ "= Template" }, symlink_source .. "/main.typ")
    local linked = uv.fs_symlink(
        symlink_source .. "/main.typ",
        symlink_source .. "/link.typ"
    )
    if linked then
        local result =
            template_files.copy_dir(symlink_source, symlink_destination, {
                source_root = symlink_source,
            })
        assert(
            result.ok == false,
            "template copy should reject symlinked package entries"
        )
        assert(
            tostring(result.error):match("symlink rejected"),
            tostring(result.error)
        )
    end
end

vim.cmd("qa!")
