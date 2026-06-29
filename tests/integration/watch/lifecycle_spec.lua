local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

local case_id = 0

local function cleanup(group)
    pcall(function()
        typst.reset({ force = true })
    end)
    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    pcall(vim.cmd, "silent! %bwipeout!")
end

local function run_case(name, fn)
    case_id = case_id + 1
    local group = vim.api.nvim_create_augroup(
        "TypstWatchLifecycle" .. case_id,
        { clear = true }
    )

    cleanup(group)
    group = vim.api.nvim_create_augroup(
        "TypstWatchLifecycle" .. case_id,
        { clear = true }
    )

    local ok, err = xpcall(function()
        fn(group)
    end, debug.traceback)

    cleanup(group)

    if not ok then
        error(("watch lifecycle case failed [%s]:\n%s"):format(name, err))
    end
end

local function setup_project(opts, prefix, lines)
    typst.reset()
    typst.setup(vim.tbl_extend("force", {
        root = root,
        output_dir = typst_test_cache_path("watch-lifecycle-output"),
        compile = {
            deps = false,
        },
    }, opts or {}))

    local fixture_dir =
        typst_test_cache_path(("%s-%d"):format(prefix, vim.uv.hrtime()))
    vim.fn.mkdir(fixture_dir, "p")
    local main = fixture_dir .. "/main.typ"
    vim.fn.writefile(lines or { "= Watch lifecycle fixture" }, main)

    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    vim.fn.delete(typst_test_compiler(project).output)
    return project, main
end

local function record(group, project, pattern, target, opts)
    opts = opts or {}
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = pattern,
        callback = function(args)
            if args.data and args.data.key == project.key then
                if not opts.watch_only or args.data.watch then
                    target[#target + 1] = args.data
                end
            end
        end,
    })
end

run_case("cycle success failure success", function(group)
    local diagnostics = require("typst.diagnostics")
    local status = require("typst.ui.status")
    local viewer_refreshes = {}
    local preview_refreshes = {}
    local callbacks = {}

    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-cycles.py"
        ),
        output_dir = typst_test_cache_path("watch-cycle-output"),
        viewer = {
            reload = function(project_state, result, opts)
                viewer_refreshes[#viewer_refreshes + 1] = {
                    key = project_state.key,
                    code = result.code,
                    cycle = result.cycle,
                    cycle_generation = result.cycle_generation,
                    stderr = result.stderr,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
        },
        preview = {
            refresh = function(project_state, result, opts)
                preview_refreshes[#preview_refreshes + 1] = {
                    key = project_state.key,
                    code = result.code,
                    cycle = result.cycle,
                    cycle_generation = result.cycle_generation,
                    stderr = result.stderr,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
        },
    }, "watch-cycle", { "= Watch cycle fixture", "", "Hello" })

    local seen = {
        started = {},
        success = {},
        failed = {},
        diagnostics = {},
    }
    record(group, project, "TypstCompileStarted", seen.started, {
        watch_only = true,
    })
    record(group, project, "TypstCompileSuccess", seen.success, {
        watch_only = true,
    })
    record(group, project, "TypstCompileFailed", seen.failed, {
        watch_only = true,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstDiagnosticsPublished",
        callback = function(args)
            if args.data and args.data.key == project.key then
                seen.diagnostics[#seen.diagnostics + 1] = args.data
            end
        end,
    })

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = {
            code = result.code,
            cycle = result.cycle,
            cycle_generation = result.cycle_generation,
            stderr = result.stderr,
        }
    end)

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher
                and typst_test_compiler(project).watcher.last_cycle_status == "success"
                and #seen.started >= 3
                and #seen.success >= 2
                and #seen.failed >= 1
                and #seen.diagnostics >= 1
                and #viewer_refreshes >= 3
                and #preview_refreshes >= 3
                and #callbacks >= 3
                and vim.fn.filereadable(typst_test_compiler(project).output)
                    == 1
        end, 20),
        "watcher did not report deterministic success/failure/success cycles: "
            .. vim.inspect({
                seen = {
                    started = #seen.started,
                    success = #seen.success,
                    failed = #seen.failed,
                    diagnostics = #seen.diagnostics,
                },
                viewer_refreshes = #viewer_refreshes,
                preview_refreshes = #preview_refreshes,
                callbacks = #callbacks,
                last_callback = callbacks[#callbacks],
                watch_cycle_status = typst_test_compiler(project).watch_cycle_status,
                last_cycle_status = typst_test_compiler(project).watcher
                        and typst_test_compiler(project).watcher.last_cycle_status
                    or nil,
            })
    )

    assert(
        seen.started[1].status == "compiling",
        "watch cycle started event should report compiling status"
    )
    assert(
        seen.success[1].status == "success",
        "watch cycle success event should report success status"
    )
    assert(
        seen.success[1].watch_status == "watching",
        "watch cycle success event should preserve watcher status"
    )
    assert(
        seen.failed[1].status == "error",
        "watch cycle failure event should report error status"
    )
    assert(
        seen.started[1].cycle_generation == 1,
        "first watch cycle should start with generation 1"
    )
    assert(
        seen.started[2].cycle_generation == 2,
        "second watch cycle should advance the cycle generation"
    )
    assert(
        seen.started[3].cycle_generation == 3,
        "third watch cycle should advance the cycle generation"
    )
    assert(
        seen.success[1].cycle_generation == seen.started[1].cycle_generation,
        "success event should keep the cycle generation from its start event"
    )
    assert(
        seen.failed[1].cycle_generation == seen.started[2].cycle_generation,
        "failure event should keep the cycle generation from its start event"
    )
    assert(
        viewer_refreshes[1].code == 0,
        "viewer refresh should receive successful cycle payloads"
    )
    assert(
        viewer_refreshes[2].code == 1,
        "viewer refresh should receive failed cycle payloads"
    )
    assert(
        viewer_refreshes[3].code == 0,
        "viewer refresh should receive later successful cycle payloads"
    )
    assert(
        preview_refreshes[1].code == 0,
        "preview refresh should receive successful cycle payloads"
    )
    assert(
        preview_refreshes[2].code == 1,
        "preview refresh should receive failed cycle payloads"
    )
    assert(
        preview_refreshes[3].code == 0,
        "preview refresh should receive later successful cycle payloads"
    )
    assert(
        callbacks[2].code == 1,
        "watch callback should receive failed cycle payloads"
    )
    assert(
        viewer_refreshes[2].stderr
            and viewer_refreshes[2].stderr:find("fake watch%-cycle failure"),
        "viewer refresh should receive failed cycle diagnostics"
    )
    assert(
        preview_refreshes[2].stderr
            and preview_refreshes[2].stderr:find("fake watch%-cycle failure"),
        "preview refresh should receive failed cycle diagnostics"
    )
    assert(
        callbacks[2].stderr
            and callbacks[2].stderr:find("fake watch%-cycle failure"),
        "watch callback should receive failed cycle diagnostics"
    )
    assert(
        viewer_refreshes[1].source == "watch" and viewer_refreshes[1].watch,
        "viewer refresh should identify watch"
    )
    assert(
        preview_refreshes[1].source == "watch" and preview_refreshes[1].watch,
        "preview refresh should identify watch"
    )
    assert(
        viewer_refreshes[2].cycle_generation == seen.failed[1].cycle_generation,
        "viewer refresh should receive the same cycle generation as failure events"
    )
    assert(
        preview_refreshes[3].cycle_generation
            == seen.success[2].cycle_generation,
        "preview refresh should receive the same cycle generation as later success events"
    )
    assert(
        typst_test_compiler(project).status == "watching",
        "project status should remain watching after watch cycles"
    )
    assert(
        typst_test_compiler(project).watcher.currently_compiling == false,
        "watcher should not report compiling after the completed cycle"
    )
    assert(
        typst_test_compiler(project).watcher.cycle >= 3,
        "watcher should count compile cycles"
    )
    assert(
        typst_test_compiler(project).watcher.cycle_generation >= 3,
        "watcher should expose the current project-level cycle generation"
    )
    assert(
        typst_test_compiler(project).watcher.last_cycle_generation
            == typst_test_compiler(project).watcher.cycle_generation,
        "watcher should expose the completed cycle generation"
    )
    assert(
        typst_test_compiler(project).watcher.last_cycle_status == "success",
        "last watcher cycle should be successful"
    )

    local snapshot = status.snapshot()
    assert(
        snapshot.watcher_cycle_generation
            == typst_test_compiler(project).watcher.cycle_generation,
        "status should expose cycle generation"
    )
    assert(
        snapshot.watcher_last_cycle_generation
            == typst_test_compiler(project).watcher.last_cycle_generation,
        "status should expose last completed cycle generation"
    )

    assert(
        vim.wait(10000, function()
            local current = vim.diagnostic.get(
                vim.api.nvim_get_current_buf(),
                { namespace = diagnostics.namespace_for(project) }
            )
            return #current == 0
        end, 20),
        "successful watch cycle did not clear stale diagnostics"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
    end)
    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "watcher did not stop after cycle test"
    )
end)

run_case("watch exits after one cycle", function(group)
    local status = require("typst.ui.status")
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-exits-after-cycle.py"
        ),
        output_dir = typst_test_cache_path("watch-exit-output"),
    }, "watch-exit", { "= Watch exits after one cycle" })

    local success_events = {}
    local failed_events = {}
    local stopped_events = {}
    local callbacks = {}
    record(group, project, "TypstCompileSuccess", success_events)
    record(group, project, "TypstCompileFailed", failed_events)
    record(group, project, "TypstCompileStopped", stopped_events)

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
                and #success_events >= 1
                and #callbacks >= 2
        end, 20),
        "watch process should exit after reporting one compile cycle"
    )

    assert(
        #success_events == 1,
        "watch process exit should not synthesize an extra compile success event"
    )
    assert(
        #failed_events == 0,
        "successful watch process exit should not emit failure events"
    )
    assert(
        #stopped_events == 0,
        "unexpected watch process exit should not look like a user stop"
    )
    assert(
        success_events[1].watch == true,
        "remaining success event should be the parsed watch cycle"
    )
    assert(
        typst_test_compiler(project).last_result
            and typst_test_compiler(project).last_result.watch == true,
        "last_result should remain the last watch cycle"
    )
    assert(
        typst_test_compiler(project).watch_cycle_status == "success",
        "project should retain the last watch cycle status"
    )

    local snapshot = status.snapshot()
    assert(
        snapshot.watching == false,
        "status should report that the watcher is no longer alive"
    )
    assert(
        snapshot.watcher_last_cycle == "success",
        "status should retain the last watch cycle result"
    )
    assert(
        snapshot.watcher_last_cycle_generation == 1,
        "status should retain the last cycle generation"
    )
end)

run_case("watch partial success exit", function(group)
    local status = require("typst.ui.status")
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-exits-partial-success.py"
        ),
        output_dir = typst_test_cache_path("watch-partial-exit-output"),
    }, "watch-partial-exit", { "= Watch partial exit" })

    local success_events = {}
    local failed_events = {}
    local callbacks = {}
    record(group, project, "TypstCompileSuccess", success_events)
    record(group, project, "TypstCompileFailed", failed_events)

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
                and #success_events == 1
                and #callbacks >= 2
        end, 20),
        "watch exit should flush a final partial success line into a completed cycle"
    )

    assert(
        #failed_events == 0,
        "partial success exit should not emit failure events"
    )
    assert(
        success_events[1].watch == true,
        "partial success event should be a watch cycle"
    )
    assert(
        success_events[1].cycle_generation == 1,
        "partial success event should keep the first cycle generation"
    )
    assert(
        typst_test_compiler(project).last_result
            and typst_test_compiler(project).last_result.watch == true,
        "last_result should remain the flushed watch cycle"
    )
    assert(
        typst_test_compiler(project).watch_cycle_status == "success",
        "partial success exit should retain successful last cycle"
    )

    local snapshot = status.snapshot()
    assert(
        snapshot.watching == false,
        "partial success exit should leave no active watcher"
    )
    assert(
        snapshot.watcher_last_cycle == "success",
        "status should retain the flushed cycle result"
    )
    assert(
        snapshot.watcher_last_cycle_generation == 1,
        "status should retain the flushed cycle generation"
    )
end)

run_case("missing output fails cycle", function(group)
    local diagnostics = require("typst.diagnostics")
    local status = require("typst.ui.status")
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-missing-output.py"
        ),
        output_dir = typst_test_cache_path("watch-missing-output"),
    }, "watch-missing-output", { "= Watch missing output" })

    local failed_events = {}
    local callbacks = {}
    record(group, project, "TypstCompileFailed", failed_events, {
        watch_only = true,
    })

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            local current = vim.diagnostic.get(
                0,
                { namespace = diagnostics.namespace_for(project) }
            )
            return typst_test_compiler(project).watcher
                and typst_test_compiler(project).watcher.last_cycle_status == "error"
                and #failed_events == 1
                and #callbacks >= 1
                and #current == 1
                and current[1].message:find("did not create", 1, true)
                    ~= nil
        end, 20),
        "missing watch output should fail the cycle and publish a diagnostic"
    )

    assert(
        failed_events[1].cycle_generation == 1,
        "missing-output failure should keep the cycle generation"
    )
    assert(
        typst_test_compiler(project).last_result
            and typst_test_compiler(project).last_result.code == 1,
        "missing-output cycle should be recorded as failed"
    )
    assert(
        typst_test_compiler(project).last_result.stderr
            and typst_test_compiler(project).last_result.stderr:find(
                "did not create",
                1,
                true
            ),
        "missing-output result should include the synthetic error"
    )

    local snapshot = status.snapshot()
    assert(
        snapshot.watching == true,
        "missing-output failure should leave the watcher alive"
    )
    assert(
        snapshot.watcher_last_cycle == "error",
        "status should expose the failed missing-output cycle"
    )
    assert(
        snapshot.diagnostics == 1,
        "status should count the missing-output diagnostic"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
    end)
    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "watcher did not stop after missing-output test"
    )
end)

run_case("delayed output retry succeeds", function(group)
    local diagnostics = require("typst.diagnostics")
    local log = require("typst.core.log")
    log.clear()
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-delayed-output.py"
        ),
        output_dir = typst_test_cache_path("watch-delayed-output"),
    }, "watch-delayed-output", { "= Watch delayed output" })
    local output = typst_test_compiler(project).output
    local release = output .. ".release"
    vim.fn.delete(output)
    vim.fn.delete(release)

    local failed_events = {}
    local callbacks = {}
    record(group, project, "TypstCompileFailed", failed_events, {
        watch_only = true,
    })

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            for _, entry in ipairs(log.entries()) do
                if
                    entry.message
                        == "watch success output missing; retrying briefly"
                    and entry.fields
                    and entry.fields.output == output
                then
                    return true
                end
            end
            return false
        end, 1),
        "watch should enter the missing-output retry path before output appears"
    )

    vim.fn.writefile({ "release" }, release)

    assert(
        vim.wait(10000, function()
            local current = vim.diagnostic.get(
                0,
                { namespace = diagnostics.namespace_for(project) }
            )
            return typst_test_compiler(project).watcher
                and typst_test_compiler(project).watcher.last_cycle_status == "success"
                and #failed_events == 0
                and #callbacks >= 1
                and callbacks[#callbacks].code == 0
                and #current == 0
                and vim.fn.filereadable(output) == 1
        end, 20),
        "watch should wait briefly for delayed successful output"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
    end)
    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "watcher did not stop after delayed-output test"
    )
end)

run_case("late old stream does not affect replacement watcher", function()
    local process = require("typst.core.process")
    local original_system = process.system
    local original_spawn = process.spawn
    local original_kill = process.kill
    local handles = {}

    local function new_handle()
        local handle = {
            id = #handles + 1,
            pid = 7000 + #handles,
            closed = false,
        }

        function handle:is_closing()
            return self.closed
        end

        function handle:finish(result)
            self.closed = true
            self.on_exit(result or { code = 0, stdout = "", stderr = "" })
        end

        return handle
    end

    local function fake_spawn(command, opts, on_exit)
        local handle = new_handle()
        handle.command = command
        handle.opts = opts
        handle.on_exit = on_exit
        handles[#handles + 1] = handle
        return handle
    end

    process.spawn = function(command, opts, handlers)
        return fake_spawn(command, opts, handlers and handlers.on_exit)
    end
    process.system = function(command, opts, on_exit)
        return fake_spawn(command, opts, on_exit)
    end
    process.kill = function(handle, signal)
        handle.killed_signal = signal
        handle.closed = true
        return true, nil, "process"
    end

    local ok, err = xpcall(function()
        local project = setup_project({
            executable = { "fake-typst" },
            output_dir = typst_test_cache_path("watch-late-stream-output"),
        }, "watch-late-stream", { "= Watch late stream fixture" })

        local first_handle = typst.compiler.watch()
        local first_watcher = typst_test_compiler(project).watcher
        assert(
            first_handle == handles[1],
            "initial watcher should return the fake process handle"
        )
        assert(
            first_watcher and first_watcher.handle == first_handle,
            "initial watcher should be tracked"
        )

        local restart_handle = typst.compiler.watch()
        assert(
            restart_handle
                and restart_handle.restart == true
                and restart_handle.stop_handle == first_handle,
            "watch restart should return a restart handle for the old watcher stop"
        )
        assert(
            typst_test_compiler(project).watcher == first_watcher
                and first_watcher.stopping,
            "old watcher should be stopping"
        )

        handles[1]:finish({ code = 0, stdout = "", stderr = "" })
        handles[1].opts.stderr(
            nil,
            "[12:34:56] compiling ...\nold watcher late chunk\n"
        )

        assert(
            vim.wait(1000, function()
                return #handles >= 2
                    and typst_test_compiler(project).watcher
                    and typst_test_compiler(project).watcher.handle
                        == handles[2]
            end, 10),
            "replacement watcher did not start after old watcher exit"
        )

        vim.wait(100, function()
            return false
        end, 10)

        local replacement = typst_test_compiler(project).watcher
        assert(
            replacement and replacement.handle == handles[2],
            "replacement watcher should still be active"
        )
        assert(
            restart_handle.next_handle == handles[2],
            "watch restart handle should update to the replacement watcher"
        )
        assert(
            not (replacement.stderr or ""):find(
                    "old watcher late chunk",
                    1,
                    true
                ),
            "late old watcher stderr was appended to the replacement watcher"
        )
        assert(
            (replacement.cycle or 0) == 0,
            "late old watcher stderr should not start a replacement watch cycle"
        )

        local stopped = false
        typst.compiler.stop({}, function(result)
            stopped = result.stopped
        end)
        handles[2]:finish({ code = 0, stdout = "", stderr = "" })

        assert(
            vim.wait(1000, function()
                return stopped
                    and typst_test_compiler(project).watcher == nil
                    and typst_test_compiler(project).status == "idle"
            end, 10),
            "replacement watcher did not stop"
        )
    end, debug.traceback)

    process.system = original_system
    process.spawn = original_spawn
    process.kill = original_kill

    if not ok then
        error(err)
    end
end)

run_case("queued stream is parsed before exit", function()
    local process = require("typst.core.process")
    local original_spawn = process.spawn
    local handles = {}

    local function new_handle()
        local handle = {
            id = #handles + 1,
            pid = 8100 + #handles,
            closed = false,
        }

        function handle:is_closing()
            return self.closed
        end

        function handle:finish(result)
            self.closed = true
            self.on_exit(result or { code = 0, stdout = "", stderr = "" })
        end

        return handle
    end

    process.spawn = function(command, opts, handlers)
        local handle = new_handle()
        handle.command = command
        handle.opts = opts
        handle.on_exit = handlers and handlers.on_exit
        handles[#handles + 1] = handle
        return handle
    end

    local ok, err = xpcall(function()
        local project = setup_project({
            executable = { "fake-typst" },
            output_dir = typst_test_cache_path(
                "watch-stream-exit-order-output"
            ),
        }, "watch-stream-exit-order", { "= Watch stream exit fixture" })
        local handle = typst.compiler.watch()
        local compiler_state = typst_test_compiler(project)
        local watcher = compiler_state.watcher

        assert(handle == handles[1], "watch should return fake process handle")
        assert(watcher and watcher.handle == handle, "watcher should be active")

        vim.fn.mkdir(vim.fs.dirname(compiler_state.output), "p")
        vim.fn.writefile({ "pdf" }, compiler_state.output)

        handle.opts.stderr(
            nil,
            "[12:34:56] compiling ...\n"
                .. "[12:34:56] compiled successfully in 31 ms\n"
        )
        handle:finish({ code = 0, stdout = "", stderr = "" })

        local final_state = typst_test_compiler(project)
        assert(
            final_state.watcher == nil and final_state.status == "idle",
            "watcher should finish after draining queued stream data"
        )
        assert(
            final_state.last_result
                and final_state.last_result.watch == true
                and final_state.last_result.cycle == 1
                and final_state.last_result.code == 0,
            "queued final stream chunk should be parsed before terminal classification"
        )
    end, debug.traceback)

    process.spawn = original_spawn

    if not ok then
        error(err)
    end
end)

run_case("output buffers are bounded", function()
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-long-partial.py"
        ),
        output_dir = typst_test_cache_path("watch-output-bounds"),
    }, "watch-output-bounds", { "= Watch output bounds fixture" })

    typst.compiler.watch()

    assert(
        vim.wait(10000, function()
            local watcher = typst_test_compiler(project).watcher
            return watcher
                and watcher.last_cycle_status == "success"
                and #((watcher.line_buffers or {}).stderr or "") == 64 * 1024
                and #(watcher.stderr or "") <= 64 * 1024
        end, 20),
        "watcher should bound aggregate output and unterminated partial-line buffers"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
    end)
    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "watcher did not stop after output-bounds test"
    )
end)

run_case("start restart stop and idle stop", function()
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("watch-output"),
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    vim.fn.delete(typst_test_compiler(project).output)

    typst.compiler.watch()

    local started = vim.wait(10000, function()
        return typst_test_compiler(project).watcher ~= nil
            and typst_test_compiler(project).status == "watching"
            and vim.fn.filereadable(typst_test_compiler(project).output)
                == 1
    end, 20)

    assert(started, "Typst watcher did not start and produce output")

    local first_handle = typst_test_compiler(project).watcher.handle
    local first_cycle_generation =
        typst_test_compiler(project).watcher.cycle_generation
    assert(
        first_cycle_generation and first_cycle_generation > 0,
        "first watcher should expose a cycle generation"
    )
    typst.compiler.watch()

    local restarted = vim.wait(10000, function()
        return typst_test_compiler(project).watcher ~= nil
            and typst_test_compiler(project).watcher.handle ~= first_handle
            and typst_test_compiler(project).status == "watching"
            and (typst_test_compiler(project).watcher.cycle_generation or 0)
                > first_cycle_generation
    end, 20)

    assert(restarted, "Typst watcher did not restart")
    assert(
        first_handle:is_closing(),
        "old watcher handle did not close after restart"
    )
    assert(
        typst_test_compiler(project).watcher.cycle_generation
            > first_cycle_generation,
        "watch cycle generation should keep increasing across watcher restarts"
    )

    local stopped = false
    local stop_deps_path = nil
    local final_handle = typst_test_compiler(project).watcher.handle
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
        stop_deps_path = result.deps_path
    end)

    local did_stop = vim.wait(10000, function()
        return stopped
            and typst_test_compiler(project).watcher == nil
            and typst_test_compiler(project).status == "idle"
    end, 20)

    assert(did_stop, "Typst watcher did not stop cleanly")
    assert(final_handle:is_closing(), "watcher handle did not close after stop")
    assert(
        stop_deps_path and stop_deps_path ~= "",
        "watch stop should report the dependency capture path"
    )
    assert(
        vim.fn.filereadable(stop_deps_path) == 0,
        "watch dependency temp file should be removed"
    )

    local idle_stop_result = nil
    local idle_stop_handle = typst.compiler.stop({}, function(result)
        idle_stop_result = result
    end)

    assert(
        idle_stop_handle == nil,
        "idle stop after watcher stop should not return a handle"
    )
    assert(
        idle_stop_result and idle_stop_result.idle,
        "idle stop after watcher stop should be marked as idle"
    )
end)

run_case("last buffer detach stops watcher", function()
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("watch-detach-output"),
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    typst.project.attach(0)
    vim.fn.delete(typst_test_compiler(project).output)

    typst.compiler.watch()

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher ~= nil
                and typst_test_compiler(project).status == "watching"
                and vim.fn.filereadable(typst_test_compiler(project).output)
                    == 1
        end, 20),
        "Typst watcher did not start and produce output"
    )

    local handle = typst_test_compiler(project).watcher.handle
    vim.cmd("bdelete")

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "Typst watcher should stop after the last buffer is deleted"
    )

    assert(
        handle:is_closing(),
        "watcher handle did not close after last buffer detach"
    )
end)

run_case("main transfer stops old watcher", function()
    local registry = require("typst.project")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("watch-transfer-output"),
    })

    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    local main = root .. "/tests/fixtures/basic/main.typ"

    vim.cmd.edit(chapter)
    local chapter_project = typst.project.set_main(chapter)
    vim.fn.delete(typst_test_compiler(chapter_project).output)

    typst.compiler.watch()

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(chapter_project).watcher ~= nil
                and typst_test_compiler(chapter_project).status == "watching"
                and vim.fn.filereadable(
                        typst_test_compiler(chapter_project).output
                    )
                    == 1
        end, 20),
        "Typst watcher did not start for the original project"
    )

    local handle = typst_test_compiler(chapter_project).watcher.handle
    local main_project = typst.project.set_main(main)
    assert(
        main_project.key ~= chapter_project.key,
        "TypstSetMain should move the buffer to another project"
    )

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(chapter_project).watcher == nil
                and typst_test_compiler(chapter_project).status == "idle"
        end, 20),
        "old project watcher should stop after the buffer moves to another main"
    )

    assert(
        handle:is_closing(),
        "old watcher handle did not close after main change"
    )
    assert(
        registry.all()[chapter_project.key] == nil,
        "old empty project should be removed after watcher stops"
    )
    assert(
        registry.all()[main_project.key] == main_project,
        "new project should remain registered"
    )
end)

run_case("watch refreshes dependency graph", function()
    local project_services = require("typst.project.services")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("watch-dependencies-output"),
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    local appendix = root .. "/tests/fixtures/basic/appendix.typ"

    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    vim.fn.delete(typst_test_compiler(project).output)

    typst.compiler.watch()

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher ~= nil
                and typst_test_compiler(project).status == "watching"
                and vim.fn.filereadable(typst_test_compiler(project).output) == 1
                and project_services.graph(project).dependencies[chapter]
                and project_services.graph(project).dependencies[appendix]
        end, 20),
        "active Typst watcher did not refresh project dependencies"
    )

    vim.cmd.edit(chapter)
    local chapter_project = typst.project.get(0)
    assert(
        chapter_project.key == project.key,
        "chapter should attach to active watcher project through dependencies"
    )
    assert(
        chapter_project.resolutions[vim.api.nvim_get_current_buf()].main_source
            == "existing project graph",
        "chapter resolution should record active watcher dependency graph attachment"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped
    end)

    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "Typst watcher did not stop cleanly"
    )
end)

vim.cmd("qa!")
