local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local diagnostics_service = require("typst.project.services.diagnostics")
local typst = require("typst")

local fixture_root = typst_test_cache_path("diagnostics-external-paths")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")

local project = {
    root = fixture_root,
    main = fixture_root .. "/main.typ",
}
vim.fn.writefile({ "= Main" }, project.main)

local function setup_diagnostics(opts)
    typst.reset({ force = true })
    typst.setup({
        root_markers = {},
        diagnostics = opts,
    })
end

local function write_fixture(name)
    local path = fixture_root .. "/" .. name
    vim.fn.writefile({ "= Fixture" }, path)
    assert(vim.fn.bufnr(path) == -1, name .. " should start without a buffer")
    return path
end

setup_diagnostics({
    external_paths = "bufadd",
    max_buffers_per_publish = 4,
})
local bufadd_path = write_fixture("bufadd-mode.typ")
local bufadd_by_buffer, bufadd_meta =
    diagnostics.parse(project, "bufadd-mode.typ:1:1: error: bufadd path")
local bufadd_bufnr = vim.fn.bufnr(bufadd_path)
assert(bufadd_bufnr > 0, "bufadd mode should create an unloaded buffer")
assert(
    not vim.api.nvim_buf_is_loaded(bufadd_bufnr),
    "bufadd mode should not load the created diagnostic buffer"
)
assert(
    #(bufadd_by_buffer[bufadd_bufnr] or {}) == 1,
    "bufadd mode should publish diagnostics to the created buffer"
)
assert(
    bufadd_meta.external_paths == "bufadd" and bufadd_meta.added_buffers == 1,
    "bufadd mode should report created external diagnostic buffers"
)

setup_diagnostics({
    external_paths = "quickfix-only",
    use_quickfix = true,
})
local quickfix_path = write_fixture("quickfix-mode.typ")
local quickfix_by_buffer, quickfix_meta =
    diagnostics.parse(project, "quickfix-mode.typ:1:1: error: quickfix path")
assert(
    vim.tbl_count(quickfix_by_buffer) == 0,
    "quickfix-only mode should not publish unopened-file buffer diagnostics"
)
assert(
    vim.fn.bufnr(quickfix_path) == -1,
    "quickfix-only mode should not create an unloaded buffer"
)
assert(
    quickfix_meta.external_paths == "quickfix-only"
        and quickfix_meta.quickfix_only_diagnostics == 1
        and quickfix_meta.quickfix_items[1].filename == quickfix_path,
    "quickfix-only mode should preserve filename-based quickfix diagnostics"
)
diagnostics.publish(project, "quickfix-mode.typ:1:1: error: quickfix path")
local quickfix_publish = (diagnostics_service.get(project) or {}).last_publish
local qf = vim.fn.getqflist({ items = 1 })
assert(
    quickfix_publish
        and quickfix_publish.external_paths == "quickfix-only"
        and quickfix_publish.quickfix_only_diagnostics == 1
        and #qf.items == 1
        and qf.items[1].text == "quickfix path",
    "quickfix-only publish should populate quickfix without hidden buffers"
)

setup_diagnostics({
    external_paths = "open-files-only",
})
local skipped_path = write_fixture("open-files-skipped.typ")
local skipped_by_buffer, skipped_meta = diagnostics.parse(
    project,
    "open-files-skipped.typ:1:1: error: skipped path"
)
assert(
    vim.tbl_count(skipped_by_buffer) == 0,
    "open-files-only mode should skip unopened external files"
)
assert(
    vim.fn.bufnr(skipped_path) == -1,
    "open-files-only mode should not create buffers for skipped files"
)
assert(
    skipped_meta.external_paths == "open-files-only"
        and skipped_meta.skipped_external_paths == 1
        and skipped_meta.first_skipped_path == skipped_path,
    "open-files-only mode should report skipped external paths"
)

local loaded_path = write_fixture("open-files-loaded.typ")
local loaded_bufnr = vim.fn.bufadd(loaded_path)
vim.fn.bufload(loaded_bufnr)
assert(
    vim.api.nvim_buf_is_loaded(loaded_bufnr),
    "open-files-only loaded fixture should be loaded before parse"
)
local loaded_by_buffer, loaded_meta =
    diagnostics.parse(project, "open-files-loaded.typ:1:1: error: loaded path")
assert(
    #(loaded_by_buffer[loaded_bufnr] or {}) == 1,
    "open-files-only mode should publish diagnostics for loaded external files"
)
assert(
    loaded_meta.external_paths == "open-files-only"
        and loaded_meta.skipped_external_paths == 0,
    "open-files-only mode should not count loaded external files as skipped"
)

vim.cmd("qa!")
