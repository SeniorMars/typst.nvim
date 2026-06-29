local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local buffer = require("typst.core.buffer")
local path = require("typst.core.path")

buffer.reset()

local fixture_dir =
    typst_test_cache_path(("buffer-index-%d"):format(vim.uv.hrtime()))
vim.fn.mkdir(fixture_dir, "p")

local first = fixture_dir .. "/first.typ"
local second = fixture_dir .. "/second.typ"
vim.fn.writefile({ "= First" }, first)

vim.cmd.edit(vim.fn.fnameescape(first))
local bufnr = vim.api.nvim_get_current_buf()

assert(
    buffer.loaded_buffer_for_path(first) == bufnr,
    "path-to-buffer index should find the loaded Typst buffer"
)

local original_list_bufs = vim.api.nvim_list_bufs
local list_bufs_calls = 0
vim.api.nvim_list_bufs = function(...)
    list_bufs_calls = list_bufs_calls + 1
    error("hot path should not rescan all buffers")
end

local ok, err = xpcall(function()
    assert(
        buffer.loaded_buffer_for_path(first) == bufnr,
        "indexed path lookup should be served from the maintained map"
    )
    local snapshot = buffer.loaded_buffers_by_path()
    assert(
        snapshot[path.path_key(first)] == bufnr,
        "snapshot should expose the maintained path-to-buffer entry"
    )
    assert(
        buffer.loaded_buffer_for_path(first, snapshot) == bufnr,
        "callers should be able to reuse a precomputed path map"
    )
end, debug.traceback)

vim.api.nvim_list_bufs = original_list_bufs
if not ok then
    error(err)
end
assert(
    list_bufs_calls == 0,
    "hot indexed buffer lookups should not call nvim_list_bufs"
)

vim.cmd("saveas! " .. vim.fn.fnameescape(second))
local renamed = buffer.loaded_buffers_by_path()
assert(
    renamed[path.path_key(first)] == nil,
    "BufFilePost should remove stale path entries after rename"
)
assert(
    renamed[path.path_key(second)] == bufnr,
    "BufFilePost should index the buffer under its new path"
)

vim.cmd("bdelete! " .. bufnr)
local after_delete = buffer.loaded_buffers_by_path()
assert(
    after_delete[path.path_key(second)] == nil,
    "BufDelete should remove unloaded buffers from the path index"
)

buffer.reset()

local bibliography_edit = require("typst.bibliography.edit")
local formatting = require("typst.formatting")
local indent = require("typst.edit.indent")
local lifecycle = require("typst.core.lifecycle")

local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
    "#let value = 1",
})
vim.bo[scratch].filetype = "typst"

assert(indent.forget(scratch), "indent.forget should accept a buffer")
assert(
    bibliography_edit.forget(scratch),
    "bibliography edit forget should accept a buffer"
)
assert(formatting.forget(scratch), "formatting.forget should accept a buffer")

lifecycle.clear_buffer(scratch)
lifecycle.clear_buffer(999999)

assert(indent.reset(), "indent.reset should clear all cache state")
assert(
    bibliography_edit.reset(),
    "bibliography edit reset should clear all cache state"
)
assert(formatting.reset(), "formatting.reset should clear all cache state")

vim.cmd("qa!")
