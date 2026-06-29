local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local output_policy = require("typst.core.output_policy")
local util = require("typst.core.util")

local tmp = util.join(
    root,
    typst_test_root_path("cache/typst.nvim"),
    "output-policy-spec"
)
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")

local project = {
    root = tmp,
}

local fragment_root_allowed, fragment_root_reason =
    output_policy.fragment_source_cleanup_allowed(tmp, project)
assert(
    not fragment_root_allowed
        and fragment_root_reason == "unsafe_fragment_source_dir",
    "fragment policy must refuse the project root"
)

local fragment_dir = util.join(tmp, "custom-fragment-source")
vim.fn.mkdir(fragment_dir, "p")
local unowned_allowed, unowned_reason =
    output_policy.fragment_source_cleanup_allowed(fragment_dir, project)
assert(
    not unowned_allowed and unowned_reason == "unsafe_fragment_source_dir",
    "fragment policy must refuse custom dirs without ownership proof"
)

assert(
    output_policy.mark_fragment_source_dir(fragment_dir),
    "fragment policy should mark custom source dirs"
)
local owned_allowed =
    output_policy.fragment_source_cleanup_allowed(fragment_dir, project)
assert(owned_allowed, "sentinel-owned fragment source dir should be allowed")

local render_dir = util.join(tmp, "render-cache")
vim.fn.mkdir(render_dir, "p")
local deleted, err = output_policy.delete_render_cache_dir(render_dir)
assert(
    not deleted and type(err) == "table" and err.reason == "unsafe_cache_dir",
    "render policy must refuse unowned cache dirs"
)

assert(
    output_policy.mark_render_cache_dir(render_dir),
    "render policy should mark cache dirs"
)
local cache_file = util.join(render_dir, "owned.svg")
local outside_file = util.join(tmp, "outside.svg")
vim.fn.writefile({ "<svg></svg>" }, cache_file)
vim.fn.writefile({ "<svg></svg>" }, outside_file)
local file_deleted, file_err =
    output_policy.delete_render_cache_file(render_dir, cache_file)
assert(
    file_deleted and vim.fn.filereadable(cache_file) == 0,
    "render policy should delete files inside the owned cache directory"
)
file_deleted, file_err =
    output_policy.delete_render_cache_file(render_dir, outside_file)
assert(
    not file_deleted
        and file_err == "outside_cache"
        and vim.fn.filereadable(outside_file) == 1,
    "render policy should refuse cache file deletes outside the cache"
)
deleted, err = output_policy.delete_render_cache_dir(render_dir)
assert(
    deleted,
    "sentinel-owned render cache dir should be deleted: " .. vim.inspect(err)
)
assert(
    vim.fn.isdirectory(render_dir) == 0,
    "sentinel-owned render cache dir should be removed"
)

vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
