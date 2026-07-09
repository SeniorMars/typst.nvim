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
    max_external_buffers = 4,
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
    external_paths = "bufadd",
    max_external_buffers = 1,
})
local cap_first_path = write_fixture("bufadd-cap-first.typ")
local cap_second_path = write_fixture("bufadd-cap-second.typ")
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
local cap_ok, cap_by_buffer, cap_meta = xpcall(function()
    return diagnostics.parse(
        project,
        table.concat({
            "bufadd-cap-first.typ:1:1: error: first capped path",
            "bufadd-cap-second.typ:1:1: error: second capped path",
        }, "\n")
    )
end, debug.traceback)
vim.notify = original_notify
assert(cap_ok, cap_by_buffer)
assert(
    vim.fn.bufnr(cap_first_path) > 0 and vim.fn.bufnr(cap_second_path) == -1,
    "bufadd mode should stop creating buffers after the configured cap"
)
assert(
    vim.tbl_count(cap_by_buffer) == 1
        and cap_meta.added_buffers == 1
        and cap_meta.skipped_by_cap == 1,
    "bufadd cap should be reported in parser metadata"
)
assert(
    #notifications == 0,
    "parser should report the bufadd cap through metadata without notifying"
)

notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
write_fixture("bufadd-publish-cap-first.typ")
write_fixture("bufadd-publish-cap-second.typ")
local publish_cap_ok, publish_cap_result = xpcall(function()
    return diagnostics.publish(
        project,
        table.concat({
            "bufadd-publish-cap-first.typ:1:1: error: first capped path",
            "bufadd-publish-cap-second.typ:1:1: error: second capped path",
        }, "\n")
    )
end, debug.traceback)
vim.notify = original_notify
assert(publish_cap_ok, publish_cap_result)
assert(
    #notifications == 1
        and notifications[1].level == vim.log.levels.WARN
        and notifications[1].message:find(
            "diagnostics.max_external_buffers=1",
            1,
            true
        ),
    "bufadd cap should emit a user-facing warning at publish boundary"
)

notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
write_fixture("bufadd-repeat-cap-first.typ")
write_fixture("bufadd-repeat-cap-second.typ")
local repeat_ok, repeat_result = xpcall(function()
    return diagnostics.publish(
        project,
        table.concat({
            "bufadd-repeat-cap-first.typ:1:1: error: first capped path",
            "bufadd-repeat-cap-second.typ:1:1: error: second capped path",
        }, "\n")
    )
end, debug.traceback)
vim.notify = original_notify
assert(repeat_ok, repeat_result)
assert(
    #notifications == 0,
    "bufadd cap warning should be emitted once per project/source/cap"
)

notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
write_fixture("bufadd-drop-cap-first.typ")
write_fixture("bufadd-drop-cap-second.typ")
local drop_warning_ok, drop_warning_result = xpcall(function()
    return diagnostics.publish(
        project,
        table.concat({
            "bufadd-drop-cap-first.typ:1:1: error: first capped path",
            "bufadd-drop-cap-second.typ:1:1: error: second capped path",
        }, "\n"),
        { overflow = "drop" }
    )
end, debug.traceback)
vim.notify = original_notify
assert(drop_warning_ok, drop_warning_result)
assert(
    #notifications == 1
        and notifications[1].message:find("overflow=drop", 1, true),
    "bufadd cap warning should be keyed by overflow policy"
)

diagnostics.reset()
notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
write_fixture("bufadd-reset-cap-first.typ")
write_fixture("bufadd-reset-cap-second.typ")
local reset_ok, reset_result = xpcall(function()
    return diagnostics.publish(
        project,
        table.concat({
            "bufadd-reset-cap-first.typ:1:1: error: first capped path",
            "bufadd-reset-cap-second.typ:1:1: error: second capped path",
        }, "\n")
    )
end, debug.traceback)
vim.notify = original_notify
assert(reset_ok, reset_result)
assert(
    #notifications == 1,
    "diagnostics.reset should clear the cap warning suppression cache"
)

notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end
local quiet_project = {
    root = fixture_root,
    main = fixture_root .. "/quiet-main.typ",
}
vim.fn.writefile({ "= Main" }, quiet_project.main)
write_fixture("bufadd-quiet-cap-first.typ")
write_fixture("bufadd-quiet-cap-second.typ")
local quiet_ok, quiet_result = xpcall(function()
    return diagnostics.publish(
        quiet_project,
        table.concat({
            "bufadd-quiet-cap-first.typ:1:1: error: first capped path",
            "bufadd-quiet-cap-second.typ:1:1: error: second capped path",
        }, "\n"),
        { notify = false }
    )
end, debug.traceback)
vim.notify = original_notify
assert(quiet_ok, quiet_result)
assert(
    #notifications == 0,
    "notify=false should suppress diagnostics cap warning at publish boundary"
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
