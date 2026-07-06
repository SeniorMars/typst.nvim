local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local index_cache = require("typst.project.index_cache")
local project_store = require("typst.project.store")
local resource_session = require("typst.resources.session")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
    project = {
        index = {
            fs_watchers = 16,
        },
    },
})

local uv = vim.uv or vim.loop
local fixture_root = typst_test_cache_path("index-fs-watch-lifecycle")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
local lib = fixture_root .. "/lib.typ"
vim.fn.writefile({ '#include "lib.typ"' }, main)
vim.fn.writefile({ "= Lib" }, lib)

local original_defer_fn = vim.defer_fn
local deferred = {}
rawset(vim, "defer_fn", function(fn)
    deferred[#deferred + 1] = fn
end)

local ok, err = xpcall(function()
    local prune_project = project_store.create(fixture_root, main)
    local prune_index = index_cache.ensure(prune_project)
    index_cache._schedule_watch_bump_for_tests(prune_index, lib)
    assert(#deferred == 1, "watch bump should schedule one deferred callback")
    assert(
        project_store.prune(prune_project, "unit prune"),
        "empty project should prune before deferred watcher callback"
    )
    deferred[1]()
    assert(
        prune_index.generation == 0,
        "deferred watcher callback after prune should not bump stale index"
    )
    assert(
        prune_index.last_fs_event_path == nil,
        "stale prune callback should not record fs event path"
    )

    deferred = {}
    local reset_main = fixture_root .. "/reset.typ"
    vim.fn.writefile({ "= Reset" }, reset_main)
    local reset_project = project_store.create(fixture_root, reset_main)
    local reset_index = index_cache.ensure(reset_project)
    index_cache._schedule_watch_bump_for_tests(reset_index, reset_main)
    assert(#deferred == 1, "reset fixture should schedule a callback")
    index_cache.reset(reset_project)
    deferred[1]()
    assert(
        reset_index.generation == 0,
        "deferred watcher callback after index reset should not bump stale index"
    )
    assert(
        reset_index.last_fs_event_path == nil,
        "stale reset callback should not record fs event path"
    )

    deferred = {}
    local live_main = fixture_root .. "/live.typ"
    vim.fn.writefile({ "= Live" }, live_main)
    local live_project = project_store.create(fixture_root, live_main)
    local live_index = index_cache.ensure(live_project)
    index_cache._schedule_watch_bump_for_tests(live_index, live_main)
    assert(#deferred == 1, "live fixture should schedule a callback")
    index_cache.sync_file_watchers(live_index, {})
    deferred[1]()
    assert(
        live_index.generation == 1,
        "deferred watcher callback should survive a no-op live watcher resync"
    )
    assert(
        live_index.last_fs_event_path == live_main,
        "live watcher callback should still record the event path"
    )
end, debug.traceback)

vim.defer_fn = original_defer_fn
if not ok then
    error(err)
end

if uv and type(uv.new_fs_event) == "function" then
    local original_new_fs_event = uv.new_fs_event
    local partial_ok, partial_err = xpcall(function()
        local partial_root = typst_test_cache_path("index-fs-watch-partial")
        vim.fn.mkdir(partial_root, "p")
        local ok_path = partial_root .. "/ok.typ"
        local fail_path = partial_root .. "/fail.typ"
        vim.fn.writefile({ "= Ok" }, ok_path)
        vim.fn.writefile({ "= Fail" }, fail_path)

        rawset(uv, "new_fs_event", function()
            local handle = { closing = false }
            function handle:start(path)
                if path == fail_path then
                    error("watch start failed")
                end
                self.path = path
            end
            function handle:stop()
                self.stopped = true
            end
            function handle:close()
                self.closing = true
            end
            function handle:is_closing()
                return self.closing == true
            end
            return handle
        end)

        local project = project_store.create(partial_root, ok_path)
        local state = index_cache.ensure(project)
        index_cache.sync_file_watchers(state, {
            [ok_path] = ok_path,
            [fail_path] = fail_path,
        })

        assert(
            state.fs_watch_mode == "watching",
            "one successful watcher should keep watch mode active"
        )
        assert(state.fs_watch_wanted_count == 2, "wanted count should be kept")
        assert(state.fs_watch_active_count == 1, "active count should be kept")
        assert(
            state.fs_watch_failed_count == 1,
            "partial watcher failure count should be tracked"
        )
        assert(
            state.fs_watch_first_failed_path == fail_path,
            "first failed watcher path should be tracked"
        )
        assert(
            state.fs_watch_partial == true,
            "partial watcher degradation should be explicit"
        )

        local snapshot = assert(resource_session.snapshot(project))
        local saw_partial = false
        for _, blocker in ipairs(snapshot.blockers or {}) do
            saw_partial = saw_partial
                or blocker.kind == "index_fs_watch_partial"
        end
        assert(
            saw_partial,
            "resource session should report partial fs watcher degradation"
        )
    end, debug.traceback)

    uv.new_fs_event = original_new_fs_event
    if not partial_ok then
        error(partial_err)
    end
end

typst.reset({ force = true })
vim.cmd("qa!")
