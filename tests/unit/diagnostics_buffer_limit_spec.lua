local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local diagnostics = require("typst.diagnostics")
local diagnostics_service = require("typst.project.services.diagnostics")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    diagnostics = {
        max_buffers_per_publish = 2,
    },
})

local fixture_root = typst_test_cache_path("diagnostics-buffer-limit")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")

local project = {
    root = fixture_root,
    main = fixture_root .. "/main.typ",
}

local paths = {
    fixture_root .. "/one.typ",
    fixture_root .. "/two.typ",
    fixture_root .. "/three.typ",
}
for _, path in ipairs(paths) do
    vim.fn.writefile({ "= File" }, path)
    assert(vim.fn.bufnr(path) == -1, "diagnostic fixture should start unloaded")
end

log.clear()
local parsed = diagnostics.parse(
    project,
    table.concat({
        "one.typ:1:1: error: first",
        "two.typ:1:1: error: second",
        "three.typ:1:1: error: skipped",
        "one.typ:1:2: warning: repeated path stays accepted",
    }, "\n")
)

assert(
    vim.tbl_count(parsed) == 2,
    "diagnostic parser should cap new diagnostic buffers per publish"
)
assert(
    vim.fn.bufnr(paths[1]) > 0 and vim.fn.bufnr(paths[2]) > 0,
    "diagnostic parser should create buffers up to the cap"
)
assert(
    vim.fn.bufnr(paths[3]) == -1,
    "diagnostic parser should not bufadd paths beyond the cap"
)

local first_bufnr = vim.fn.bufnr(paths[1])
assert(
    #(parsed[first_bufnr] or {}) == 2,
    "diagnostic parser should keep repeated diagnostics for an accepted buffer"
)
local entries = log.entries()
local limit_log = entries[#entries]
assert(
    limit_log
        and limit_log.message == "diagnostic buffer limit reached"
        and limit_log.fields.skipped_buffers == 1
        and limit_log.fields.first_skipped_path == paths[3],
    "diagnostic parser should log skipped diagnostic buffer count and first path"
)

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    diagnostics = {
        max_buffers_per_publish = 1,
    },
})

local extra_paths = {
    fixture_root .. "/four.typ",
    fixture_root .. "/five.typ",
}
for _, path in ipairs(extra_paths) do
    vim.fn.writefile({ "= File" }, path)
    assert(
        vim.fn.bufnr(path) == -1,
        "extra diagnostic fixture should start unloaded"
    )
end

local existing_plus_new = diagnostics.parse(
    project,
    table.concat({
        "one.typ:1:1: error: existing buffers do not spend cap",
        "four.typ:1:1: error: accepted new hidden buffer",
        "five.typ:1:1: error: skipped new hidden buffer",
    }, "\n")
)
assert(
    vim.tbl_count(existing_plus_new) == 2,
    "existing buffers should not consume the new-buffer diagnostic cap"
)
assert(
    vim.fn.bufnr(extra_paths[1]) > 0,
    "diagnostic parser should still accept one new buffer after existing buffers"
)
assert(
    vim.fn.bufnr(extra_paths[2]) == -1,
    "diagnostic parser should cap only additional new hidden buffers"
)

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    diagnostics = {
        max_buffers_per_publish = 0,
    },
})

local unlimited = diagnostics.parse(
    project,
    table.concat({
        "one.typ:1:1: error: first",
        "two.typ:1:1: error: second",
        "three.typ:1:1: error: third",
    }, "\n")
)
assert(
    vim.tbl_count(unlimited) == 3,
    "diagnostic buffer cap value 0 should allow all parsed buffers"
)

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    diagnostics = {
        external_paths = "open-files-only",
        max_buffers_per_publish = 2,
    },
})

local open_only_path = fixture_root .. "/open-only.typ"
vim.fn.writefile({ "= File" }, open_only_path)
assert(
    vim.fn.bufnr(open_only_path) == -1,
    "open-files-only diagnostic fixture should start unloaded"
)

local open_only, open_only_meta = diagnostics.parse(
    project,
    "open-only.typ:1:1: error: skipped unopened path"
)
assert(
    vim.tbl_count(open_only) == 0,
    "open-files-only should not publish diagnostics for unloaded files"
)
assert(
    vim.fn.bufnr(open_only_path) == -1,
    "open-files-only should not create unloaded diagnostic buffers"
)
assert(
    open_only_meta
        and open_only_meta.external_paths == "open-files-only"
        and open_only_meta.skipped_external_paths == 1
        and open_only_meta.first_skipped_path == open_only_path,
    "open-files-only should report skipped external diagnostic paths"
)

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    diagnostics = {
        external_paths = "quickfix-only",
        use_quickfix = true,
    },
})

local quickfix_only_path = fixture_root .. "/quickfix-only.typ"
vim.fn.writefile({ "= File" }, quickfix_only_path)
assert(
    vim.fn.bufnr(quickfix_only_path) == -1,
    "quickfix-only diagnostic fixture should start unloaded"
)

local quickfix_only, quickfix_only_meta =
    diagnostics.parse(project, "quickfix-only.typ:1:1: error: quickfix path")
assert(
    vim.tbl_count(quickfix_only) == 0,
    "quickfix-only should not publish buffer diagnostics for unloaded files"
)
assert(
    quickfix_only_meta
        and quickfix_only_meta.quickfix_only_diagnostics == 1
        and #quickfix_only_meta.quickfix_items == 1
        and quickfix_only_meta.quickfix_items[1].filename
            == quickfix_only_path,
    "quickfix-only should return filename-based quickfix diagnostics"
)
assert(
    vim.fn.bufnr(quickfix_only_path) == -1,
    "quickfix-only parser path should not create unloaded diagnostic buffers"
)

local published =
    diagnostics.publish(project, "quickfix-only.typ:1:1: error: quickfix path")
assert(
    published and vim.tbl_count(published) == 0,
    "quickfix-only publish should not create buffer diagnostics for unloaded files"
)
local diagnostic_state = diagnostics_service.get(project) or {}
assert(
    next(diagnostic_state.buffers or {}) == nil,
    "quickfix-only publish should not track unopened files as diagnostic buffers"
)
local qf = vim.fn.getqflist({ items = 1, title = 1 })
assert(
    qf.title == "typst.nvim: main.typ" and #qf.items == 1,
    "quickfix-only publish should still populate the configured diagnostics list"
)
assert(
    qf.items[1].text == "quickfix path",
    "quickfix-only quickfix item should preserve diagnostic message"
)
vim.fn.setqflist({}, "r", { title = "user list", items = {} })
local reopened = diagnostics.quickfix(project, { open = false })
assert(
    #reopened == 1 and reopened[1].text == "quickfix path",
    "quickfix-only diagnostics should reopen after quickfix is replaced"
)

vim.cmd("qa!")
