local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local attachments = require("typst.project.attachments")
local attachment_toc = require("typst.project.attachments.toc")
local cache_registry = require("typst.core.cache_registry")
local config = require("typst.config")
local core_lifecycle = require("typst.core.lifecycle")
local project = require("typst.project")
local project_store = require("typst.project.store")

local function buffer_autocmd_count(bufnr)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
        group = core_lifecycle.buffer_augroup_name(bufnr),
        buffer = bufnr,
    })
    return ok and #autocmds or 0
end

typst.reset()
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
})

local fixture_root = typst_test_cache_path("reload-transaction")
vim.fn.mkdir(fixture_root, "p")
local chapter = fixture_root .. "/chapter.typ"
local main_a = fixture_root .. "/main-a.typ"
local main_b = fixture_root .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, chapter)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, main_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, main_b)

vim.cmd.edit(chapter)
vim.bo.filetype = "typst"
vim.b.typst_main = main_a

local original = typst.project.attach(0)
assert(original and original.main == main_a, "fixture should attach main A")
local bufnr = vim.api.nvim_get_current_buf()
local original_autocmd_count = buffer_autocmd_count(bufnr)
assert(original_autocmd_count > 0, "fixture should install buffer autocmds")

local original_install = attachments.install
local install_calls = 0
rawset(attachments, "install", function(...)
    install_calls = install_calls + 1
    if install_calls == 1 then
        error("install failed during reload")
    end
    return original_install(...)
end)

vim.b.typst_main = main_b
local reloaded, err = typst.project.reload_state({
    notify = false,
})

rawset(attachments, "install", original_install)

assert(reloaded == nil, "reload should fail when buffer install fails")
assert(
    type(err) == "table" and err.reason == "reload_failed",
    "reload failure should be structured"
)

local current = project_store.project_for_buffer(vim.api.nvim_get_current_buf())
assert(current ~= nil, "failed reload should preserve a project attachment")
assert(
    current.main == main_a,
    "failed reload should restore the previous attached main"
)
assert(
    err.rollback_ok == true,
    "successful rollback should be reported in the structured failure"
)
assert(
    buffer_autocmd_count(bufnr) == original_autocmd_count,
    "install failure rollback should restore previous buffer autocmds"
)
local restored_features =
    core_lifecycle.apply_buffer_features_all_windows(bufnr)
assert(
    restored_features.buffer == false,
    "install failure rollback should restore buffer feature signatures"
)
assert(
    restored_features.window == false,
    "install failure rollback should restore window feature signatures"
)

typst.reset()
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
})

local fixture_root_failed = typst_test_cache_path("reload-rollback-failure")
vim.fn.mkdir(fixture_root_failed, "p")
local chapter_failed = fixture_root_failed .. "/chapter.typ"
local main_failed_a = fixture_root_failed .. "/main-a.typ"
local main_failed_b = fixture_root_failed .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, chapter_failed)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, main_failed_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, main_failed_b)

vim.cmd.edit(chapter_failed)
vim.bo.filetype = "typst"
vim.b.typst_main = main_failed_a

local original_failed = typst.project.attach(0)
assert(
    original_failed and original_failed.main == main_failed_a,
    "second fixture should attach main A"
)
local failed_bufnr = vim.api.nvim_get_current_buf()

original_install = attachments.install
rawset(attachments, "install", function()
    error("install failed during reload and rollback")
end)

vim.b.typst_main = main_failed_b
local failed_reload, failed_err = typst.project.reload_state({
    notify = false,
})

rawset(attachments, "install", original_install)

assert(
    failed_reload == nil,
    "reload should fail when reload and rollback hook installation fail"
)
assert(
    type(failed_err) == "table"
        and failed_err.reason == "reload_failed"
        and failed_err.rollback_ok == false
        and type(failed_err.rollback_error) == "string",
    "reload failure should report failed rollback hook restoration"
)

local failed_current =
    project_store.project_for_buffer(vim.api.nvim_get_current_buf())
assert(
    failed_current == nil,
    "failed rollback hook restoration should not leave a falsely attached buffer"
)
assert(
    buffer_autocmd_count(failed_bufnr) == 0,
    "failed rollback hook restoration should clear buffer autocmds"
)

typst.reset()
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
})

local fixture_root_commit = typst_test_cache_path("reload-commit-failure")
vim.fn.mkdir(fixture_root_commit, "p")
local chapter_commit = fixture_root_commit .. "/chapter.typ"
local main_commit_a = fixture_root_commit .. "/main-a.typ"
local main_commit_b = fixture_root_commit .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, chapter_commit)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, main_commit_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, main_commit_b)

vim.cmd.edit(chapter_commit)
vim.bo.filetype = "typst"
vim.b.typst_main = main_commit_a

local original_commit = typst.project.attach(0)
assert(
    original_commit and original_commit.main == main_commit_a,
    "third fixture should attach main A"
)
local commit_bufnr = vim.api.nvim_get_current_buf()
local commit_autocmd_count = buffer_autocmd_count(commit_bufnr)
assert(
    commit_autocmd_count > 0,
    "commit fixture should install buffer autocmds"
)

local outside_output_dir = vim.fn.tempname() .. "-typst-nvim-output"
vim.fn.mkdir(outside_output_dir, "p")
config.unsafe_get().output_dir = outside_output_dir

vim.b.typst_main = main_commit_b
local commit_failed_reload, commit_failed_err = typst.project.reload_state({
    notify = false,
})

assert(
    commit_failed_reload == nil,
    "reload should fail when commit output validation fails"
)
assert(
    type(commit_failed_err) == "table"
        and commit_failed_err.reason == "reload_failed"
        and commit_failed_err.stage == "commit"
        and commit_failed_err.rollback_ok == true,
    "commit failure should be structured and should roll back"
)

local commit_current =
    project_store.project_for_buffer(vim.api.nvim_get_current_buf())
assert(
    commit_current and commit_current.main == main_commit_a,
    "commit failure rollback should restore the original project"
)

local failed_candidate_key =
    project_store.project_key(fixture_root_commit, main_commit_b)
assert(
    project_store.get(failed_candidate_key) == nil,
    "failed reload candidate should not remain as a stale project"
)
assert(
    buffer_autocmd_count(commit_bufnr) == commit_autocmd_count,
    "commit failure rollback should restore previous buffer autocmds"
)
local commit_restored_features =
    core_lifecycle.apply_buffer_features_all_windows(commit_bufnr)
assert(
    commit_restored_features.buffer == false,
    "commit failure rollback should restore buffer feature signatures"
)
assert(
    commit_restored_features.window == false,
    "commit failure rollback should restore window feature signatures"
)

typst.reset()
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
})

local fixture_root_order = typst_test_cache_path("reload-cache-order")
vim.fn.mkdir(fixture_root_order, "p")
local chapter_order = fixture_root_order .. "/chapter.typ"
local main_order_a = fixture_root_order .. "/main-a.typ"
local main_order_b = fixture_root_order .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, chapter_order)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, main_order_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, main_order_b)

vim.cmd.edit(chapter_order)
vim.bo.filetype = "typst"
vim.b.typst_main = main_order_a

local original_order = typst.project.attach(0)
assert(
    original_order and original_order.main == main_order_a,
    "fourth fixture should attach main A"
)

local original_reload = cache_registry.reload
local original_resolve_candidate = project.resolve_candidate
local order_ok, order_err = xpcall(function()
    local reload_seen = false
    rawset(cache_registry, "reload", function(...)
        reload_seen = true
        return original_reload(...)
    end)
    rawset(project, "resolve_candidate", function(...)
        assert(
            reload_seen,
            "reload should refresh resolution-affecting caches before resolve"
        )
        return original_resolve_candidate(...)
    end)

    vim.b.typst_main = main_order_b
    local ordered_reload, ordered_err = typst.project.reload_state({
        notify = false,
    })
    assert(
        ordered_reload and ordered_reload.main == main_order_b,
        "reload should still complete after pre-resolution cache refresh"
    )
    assert(ordered_err == nil, "ordered reload should not return an error")
    assert(
        ordered_reload.last_reload_cache
            and ordered_reload.last_reload_cache.import_scan == true,
        "reload snapshot should expose the cache groups refreshed before resolve"
    )

    local refreshed_main = nil
    local original_schedule_refresh = attachment_toc.schedule_refresh
    rawset(attachment_toc, "schedule_refresh", function(state)
        refreshed_main = state and state.main or nil
        return true
    end)
    local autocmd_ok, autocmd_err = xpcall(function()
        vim.api.nvim_exec_autocmds("BufWritePost", {
            buffer = vim.api.nvim_get_current_buf(),
            modeline = false,
        })
    end, debug.traceback)
    rawset(attachment_toc, "schedule_refresh", original_schedule_refresh)
    if not autocmd_ok then
        error(autocmd_err)
    end
    assert(
        refreshed_main == main_order_b,
        "post-reload buffer autocmds should resolve the new project lazily"
    )
end, debug.traceback)

rawset(cache_registry, "reload", original_reload)
rawset(project, "resolve_candidate", original_resolve_candidate)

if not order_ok then
    error(order_err)
end

vim.cmd("qa!")
