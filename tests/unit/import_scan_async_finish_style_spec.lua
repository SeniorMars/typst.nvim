local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local util = require("typst.core.util")

local function wait_result(handle, label)
    local result
    handle:on_finish(function(final)
        result = final
    end)
    assert(
        vim.wait(1000, function()
            return result ~= nil
        end, 10),
        label
    )
    return result
end

root_discovery._clear_import_scan_cache()

local workdir = typst_test_cache_path("import-scan-async-finish-style")
vim.fn.delete(workdir, "rf")
vim.fn.mkdir(workdir, "p")

local main = util.normalize(workdir .. "/main.typ")
local leaf = util.normalize(workdir .. "/leaf.typ")
vim.fn.writefile({ '#include "leaf.typ"', "= Main" }, main)
vim.fn.writefile({ "= Leaf" }, leaf)

local opts = {
    project = {
        import_scan = true,
        import_scan_max_files = 20,
        import_scan_max_depth = 0,
        import_scan_max_entries = 100,
    },
}

local cached =
    root_discovery.import_scan_main(leaf, workdir, "buffer directory", opts)
assert(util.same_path(cached, main), "sync import scan should seed cache")

local cached_handle = assert(
    root_discovery.import_scan_main_async(
        leaf,
        workdir,
        "buffer directory",
        opts,
        { delay_ms = 0 }
    ),
    "cached async scan should return pending handle"
)
local cached_result =
    wait_result(cached_handle, "cached async scan should finish")
assert(cached_result.ok == true, "cached async result should be ok")
assert(cached_result.cached == true, "cached async result should report cache")
assert(
    util.same_path(cached_result.main, main),
    "cached async scan should find cached main"
)

root_discovery._clear_import_scan_cache()
local scan_handle = assert(
    root_discovery.import_scan_main_async(
        leaf,
        workdir,
        "buffer directory",
        opts,
        { delay_ms = 0 }
    ),
    "async scan should return pending handle"
)
local scan_result = wait_result(scan_handle, "async scan should finish")
assert(scan_result.ok == true, "async scan result should be ok")
assert(scan_result.status == "matched", "async scan should report match")
assert(util.same_path(scan_result.main, main), "async scan should resolve main")

root_discovery._clear_import_scan_cache()
local cancel_handle = assert(
    root_discovery.import_scan_main_async(
        leaf,
        workdir,
        "buffer directory",
        opts,
        { delay_ms = 1000 }
    ),
    "cancel fixture should return pending handle"
)
local cancel_result
cancel_handle:on_finish(function(final)
    cancel_result = final
end)
local stopped, returned = cancel_handle:cancel({ reason = "unit_cancel" })
assert(stopped == true, "async scan cancel should stop pending handle")
assert(returned.cancelled == true, "cancel return should be cancelled")
assert(cancel_result.cancelled == true, "cancel callback should be cancelled")
assert(
    cancel_result.reason == "unit_cancel",
    "cancel callback should preserve reason"
)

root_discovery._clear_import_scan_cache()
local uv = vim.uv or vim.loop
local original_scandir_next = uv.fs_scandir_next
local ok, error_result = pcall(function()
    uv.fs_scandir_next = function()
        error("synthetic scandir failure")
    end
    local error_handle = assert(
        root_discovery.import_scan_main_async(
            leaf,
            workdir,
            "buffer directory",
            opts,
            { delay_ms = 0 }
        ),
        "error fixture should return pending handle"
    )
    return wait_result(error_handle, "async scan error should finish")
end)
uv.fs_scandir_next = original_scandir_next
assert(ok, error_result)
assert(error_result.ok == false, "async scan error should return failure")
assert(
    error_result.reason == "scan_failed",
    "async scan error should preserve failure reason"
)

vim.cmd("qa!")
