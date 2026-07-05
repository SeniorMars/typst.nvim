local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local state_store = require("typst.core.state")
local owned_path = require("typst.core.owned_path")
local files = require("typst.core.files")
local util = require("typst.core.util")

local workdir = typst_test_cache_path("file-ops")
vim.fn.mkdir(workdir, "p")

---@param path any
local function readable_any(path)
    return files.readable(path)
end

assert(files.readable(nil) == false, "readable should reject nil paths")
assert(readable_any(false) == false, "readable should reject boolean paths")
assert(readable_any({}) == false, "readable should reject table paths")
assert(files.readable("") == false, "readable should reject empty paths")

local original_writefile = vim.fn.writefile
rawset(vim.fn, "writefile", function()
    return -1
end)
local ok, err =
    util.writefile_checked({ "new" }, workdir .. "/failed-write.txt")
assert(
    not ok and tostring(err):find("writefile returned", 1, true),
    "writefile_checked should reject nonzero returns"
)

local atomic_path = workdir .. "/atomic.txt"
original_writefile({ "old" }, atomic_path)
ok = util.atomic_writefile({ "new" }, atomic_path)
assert(
    not ok,
    "atomic_writefile should fail when temporary write returns nonzero"
)
assert(
    vim.fn.readfile(atomic_path)[1] == "old",
    "atomic_writefile should keep old content"
)

vim.fn.writefile = original_writefile

local original_delete = vim.fn.delete
rawset(vim.fn, "delete", function()
    return -1
end)
ok, err = util.delete_checked(workdir .. "/missing-delete.txt")
assert(
    not ok and tostring(err):find("delete returned", 1, true),
    "delete_checked should reject nonzero returns"
)

vim.fn.delete = original_delete

local owned_root = workdir .. "/owned-tree"
original_delete(owned_root, "rf")
vim.fn.mkdir(owned_root, "p")

local unowned_dir = owned_root .. "/unowned"
vim.fn.mkdir(unowned_dir, "p")
original_writefile({ "keep" }, unowned_dir .. "/keep.txt")
ok, err = util.delete_owned_tree(unowned_dir, {
    root = owned_root,
    reason = "unsafe_test_tree",
})
assert(
    not ok and type(err) == "table" and err.reason == "unsafe_test_tree",
    "delete_owned_tree should refuse directories without ownership proof"
)
assert(
    vim.fn.filereadable(unowned_dir .. "/keep.txt") == 1,
    "delete_owned_tree should preserve unowned directory contents"
)
ok, err = owned_path.check_tree(unowned_dir, {
    root = owned_root,
    reason = "unsafe_test_tree",
})
assert(
    not ok and type(err) == "table" and err.reason == "unsafe_test_tree",
    "owned_path.check_tree should expose refusal reasons before deletion"
)

ok, err = util.delete_owned_tree(owned_root, {
    root = owned_root,
    allow = true,
})
assert(
    not ok and type(err) == "table" and err.reason == "root_refused",
    "delete_owned_tree should refuse root equality by default"
)
assert(
    vim.fn.isdirectory(owned_root) == 1,
    "delete_owned_tree should preserve refused roots"
)

if vim.uv.fs_symlink then
    local symlink_target_dir = owned_root .. "/symlink-target"
    local symlink_dir = owned_root .. "/symlink-dir"
    vim.fn.mkdir(symlink_target_dir, "p")
    original_writefile({ "keep" }, symlink_target_dir .. "/keep.txt")
    if vim.uv.fs_symlink(symlink_target_dir, symlink_dir) then
        ok, err = util.delete_owned_tree(symlink_dir, {
            root = owned_root,
            allow = true,
        })
        assert(
            not ok
                and type(err) == "table"
                and err.reason == "symlink_unsupported",
            "delete_owned_tree should refuse symlinked directory roots"
        )
        assert(
            vim.fn.filereadable(symlink_target_dir .. "/keep.txt") == 1,
            "delete_owned_tree should preserve symlink targets"
        )
    end
end

local sentinel_dir = owned_root .. "/sentinel"
vim.fn.mkdir(sentinel_dir, "p")
original_writefile({ "owned" }, sentinel_dir .. "/.owned")
original_writefile({ "delete" }, sentinel_dir .. "/generated.txt")
ok, err = util.delete_owned_tree(sentinel_dir, {
    root = owned_root,
    sentinel = sentinel_dir .. "/.owned",
})
assert(ok, vim.inspect(err))
assert(
    vim.fn.isdirectory(sentinel_dir) == 0,
    "delete_owned_tree should delete sentinel-owned directories"
)

local default_dir = owned_root .. "/default"
vim.fn.mkdir(default_dir, "p")
original_writefile({ "delete" }, default_dir .. "/generated.txt")
ok, err = util.delete_owned_tree(default_dir, {
    root = owned_root,
    allow = function(path)
        return util.same_path(path, default_dir)
    end,
})
assert(ok, vim.inspect(err))
assert(
    vim.fn.isdirectory(default_dir) == 0,
    "delete_owned_tree should delete directories allowed by policy"
)

local atomic_calls = 0
local original_atomic_writefile = util.atomic_writefile
util.atomic_writefile = function(lines, path)
    atomic_calls = atomic_calls + 1
    assert(
        path:match("state%.json$"),
        "persisted state should write the state JSON file"
    )
    return original_atomic_writefile(lines, path)
end

state_store.reset_cache()
state_store.set_explicit_main(workdir .. "/chapter.typ", workdir .. "/main.typ")

util.atomic_writefile = original_atomic_writefile
assert(atomic_calls > 0, "persisted state should use atomic_writefile")

local mode_path = workdir .. "/mode.txt"
original_writefile({ "old" }, mode_path)
if vim.uv.fs_chmod then
    vim.uv.fs_chmod(mode_path, 384)
end
ok, err = util.atomic_writefile({ "new" }, mode_path)
assert(ok, tostring(err))
local mode_stat = vim.uv.fs_stat(mode_path)
if mode_stat and mode_stat.mode then
    assert(
        mode_stat.mode % 512 == 384,
        "atomic_writefile should preserve existing file permissions"
    )
end

if vim.uv.fs_symlink then
    local symlink_target = workdir .. "/symlink-target.txt"
    local symlink_path = workdir .. "/symlink.txt"
    original_writefile({ "target" }, symlink_target)
    if vim.uv.fs_symlink(symlink_target, symlink_path) then
        ok, err = util.atomic_writefile({ "new" }, symlink_path)
        assert(
            not ok
                and type(err) == "table"
                and err.reason == "symlink_unsupported",
            "atomic_writefile should refuse symlink destinations"
        )
        assert(
            vim.fn.readfile(symlink_target)[1] == "target",
            "atomic_writefile should not modify a symlink target"
        )
    end
end

if vim.uv.fs_fsync then
    local durable_path = workdir .. "/durable.txt"
    local fsync_calls = 0
    local original_fsync = vim.uv.fs_fsync
    vim.uv.fs_fsync = function(fd)
        fsync_calls = fsync_calls + 1
        return original_fsync(fd)
    end

    ok, err = files.atomic_writefile({ "durable" }, durable_path, {
        durable = true,
    })
    vim.uv.fs_fsync = original_fsync
    assert(ok, vim.inspect(err))
    assert(
        fsync_calls >= 2,
        "durable atomic_writefile should fsync the journal/temp file"
    )
    assert(
        vim.fn.readfile(durable_path)[1] == "durable",
        "durable atomic_writefile should write the final file"
    )
    local leftovers = vim.fn.glob(
        workdir .. "/.durable.txt.typst-nvim-journal-*",
        false,
        true
    )
    assert(#leftovers == 0, "successful durable write should remove journal")
end

vim.cmd("qa!")
