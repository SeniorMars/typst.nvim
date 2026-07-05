local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local transaction = require("typst.ui.label_rename_transaction")

local uv = vim.uv or vim.loop
local fixture_dir = typst_test_cache_path("label-rename-transaction-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(fixture_dir, "p")

local original = fixture_dir .. "/main.typ"
local backup = fixture_dir .. "/.main.typ.backup"
local temp = fixture_dir .. "/.main.typ.rename"
vim.fn.writefile({ "<old>" }, original)

local original_rename = uv.fs_rename
local ok, err = xpcall(function()
    rawset(uv, "fs_rename", function(src, dst)
        if src == temp and dst == original then
            return nil, "forced replacement failure"
        end
        if src == backup and dst == original then
            return nil, "forced restore failure"
        end
        return original_rename(src, dst)
    end)

    local applied, result = transaction.apply({
        {
            path = original,
            original_lines = { "<old>" },
            lines = { "<new>" },
            temp_path = temp,
            backup_path = backup,
        },
    })
    ---@type any
    local payload = result
    assert(not applied, "failed replacement should fail the transaction")
    assert(
        payload.reason == "write_failed",
        "failure should report write_failed"
    )
    assert(
        payload.message == "forced replacement failure",
        "failure should report the replacement error"
    )
    assert(payload.recovery, "failure should include recovery paths")
    assert(
        payload.recovery.original == original
            and payload.recovery.backup == backup
            and payload.recovery.temporary == temp,
        "recovery paths should identify original, backup, and temporary files"
    )
    assert(
        payload.recovery.restore_error == "forced restore failure",
        "recovery should report restore failure"
    )
    assert(
        vim.fn.filereadable(backup) == 1,
        "failed restore should preserve the backup"
    )
    assert(
        vim.fn.filereadable(temp) == 1,
        "failed restore should preserve the temporary replacement"
    )
end, debug.traceback)

uv.fs_rename = original_rename

if not ok then
    error(err)
end

vim.cmd("qa!")
