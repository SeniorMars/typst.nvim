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
    local group = vim.api.nvim_create_augroup("TypstWatchProcess" .. case_id, {
        clear = true,
    })

    cleanup(group)
    group = vim.api.nvim_create_augroup("TypstWatchProcess" .. case_id, {
        clear = true,
    })

    local ok, err = xpcall(function()
        fn(group)
    end, debug.traceback)

    cleanup(group)

    if not ok then
        error(("watch process case failed [%s]:\n%s"):format(name, err))
    end
end

local function setup_project(opts, main_path, main_lines)
    typst.reset()
    typst.setup(vim.tbl_extend("force", {
        root = root,
        output_dir = typst_test_cache_path("watch-process-output"),
        compile = {
            deps = false,
        },
    }, opts or {}))

    local main = main_path or root .. "/tests/fixtures/basic/main.typ"
    if main_lines then
        vim.fn.mkdir(vim.fs.dirname(main), "p")
        vim.fn.writefile(main_lines, main)
    end
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    return project, main
end

local function pid_alive(pid)
    if type(pid) ~= "number" then
        return false
    end

    local ok, result = pcall(vim.uv.kill, pid, 0)
    return ok and result == 0
end

run_case("process group stop terminates child", function()
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        return
    end

    local marker = typst_test_cache_path("watch-process-group/marker.json")
    vim.fn.delete(marker)
    vim.fn.mkdir(vim.fs.dirname(marker), "p")

    local old_marker = vim.env.TYPST_NVIM_PROCESS_TREE_MARKER
    vim.env.TYPST_NVIM_PROCESS_TREE_MARKER = marker

    local ok, err = xpcall(function()
        local workdir = typst_test_cache_path("watch-process-group")
        local main = workdir .. "/main.typ"
        local project = setup_project({
            executable = helpers.python_command(
                root .. "/tests/fixtures/fake-typst-process-tree.py"
            ),
            output_dir = typst_test_cache_path("watch-process-group-output"),
        }, main, { "= Process group fixture" })

        typst.compiler.watch()

        assert(
            vim.wait(10000, function()
                return typst_test_compiler(project).watcher
                    and typst_test_compiler(project).watcher.handle
                    and typst_test_compiler(project).watcher.handle.pid
                    and vim.fn.filereadable(marker) == 1
            end, 20),
            "fake watcher did not start and report process-tree metadata"
        )

        local metadata =
            vim.json.decode(table.concat(vim.fn.readfile(marker), "\n"))
        assert(
            pid_alive(metadata.child),
            "fake watcher child process should be running before stop"
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
            "watcher did not stop after process-group termination"
        )

        local child_stopped = vim.wait(10000, function()
            return not pid_alive(metadata.child)
        end, 20)
        if not child_stopped then
            pcall(vim.uv.kill, metadata.child, 15)
        end

        assert(
            child_stopped,
            "watcher stop should terminate child processes in the same process group"
        )
    end, debug.traceback)

    vim.env.TYPST_NVIM_PROCESS_TREE_MARKER = old_marker
    if not ok then
        error(err)
    end
end)

run_case("stop flushes partial success line", function(group)
    local status = require("typst.ui.status")
    local fixture_dir = typst_test_cache_path(
        ("watch-stop-partial-success-%d"):format(vim.uv.hrtime())
    )
    local main = fixture_dir .. "/main.typ"
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-stop-partial-success.py"
        ),
        output_dir = typst_test_cache_path("watch-stop-partial-success-output"),
    }, main, { "= Watch stop partial success" })
    vim.fn.delete(typst_test_compiler(project).output)

    local success_events = {}
    local failed_events = {}
    local stopped_events = {}
    local callbacks = {}

    local function record(pattern, target)
        vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = pattern,
            callback = function(args)
                if args.data and args.data.key == project.key then
                    target[#target + 1] = args.data
                end
            end,
        })
    end

    record("TypstCompileSuccess", success_events)
    record("TypstCompileFailed", failed_events)
    record("TypstCompileStopped", stopped_events)

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            local watcher = typst_test_compiler(project).watcher
            return watcher
                and watcher.currently_compiling == true
                and ((watcher.line_buffers or {}).stderr or ""):find(
                    "compiled successfully",
                    1,
                    true
                )
                and vim.fn.filereadable(typst_test_compiler(project).output)
                    == 1
        end, 20),
        "watcher did not buffer the unterminated success line before stop"
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
                and #success_events == 1
        end, 20),
        "TypstStop should flush a pending partial success line before clearing the watcher"
    )

    assert(
        #failed_events == 0,
        "stopping after a partial success line should not emit a failure event"
    )
    assert(
        #stopped_events == 1,
        "explicit stop should still emit one stopped event"
    )
    assert(
        success_events[1].watch == true,
        "flushed success event should be a watch cycle"
    )
    assert(
        success_events[1].cycle_generation == 1,
        "flushed success event should keep the cycle generation"
    )
    assert(
        typst_test_compiler(project).last_result
            and typst_test_compiler(project).last_result.watch == true,
        "last_result should remain the flushed watch cycle"
    )
    assert(
        typst_test_compiler(project).watch_cycle_status == "success",
        "explicit stop should retain the successful last cycle"
    )
    assert(
        #callbacks >= 2,
        "watch callback should receive the flushed cycle and final stop payload"
    )

    local snapshot = status.snapshot()
    assert(
        snapshot.watching == false,
        "status should report that the watcher is no longer alive"
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

run_case("queued restarts debounce stop", function()
    local log = require("typst.core.log")
    local marker = typst_test_cache_path("watch-restart-debounce/starts.txt")
    vim.fn.delete(marker)
    vim.fn.mkdir(vim.fs.dirname(marker), "p")

    local old_marker = vim.env.TYPST_NVIM_SLOW_WATCH_MARKER
    vim.env.TYPST_NVIM_SLOW_WATCH_MARKER = marker

    local ok, err = xpcall(function()
        local workdir = typst_test_cache_path("watch-restart-debounce")
        local main = workdir .. "/main.typ"
        local project = setup_project({
            executable = helpers.python_command(
                root .. "/tests/fixtures/fake-typst-watch-slow-stop.py"
            ),
            output_dir = typst_test_cache_path("watch-restart-debounce-output"),
        }, main, { "= Watch restart debounce fixture" })

        typst.compiler.watch()

        assert(
            vim.wait(10000, function()
                return typst_test_compiler(project).watcher
                    and typst_test_compiler(project).watcher.last_cycle_status == "success"
                    and vim.fn.filereadable(
                            typst_test_compiler(project).output
                        )
                        == 1
            end, 20),
            "initial watcher did not start before restart debounce test"
        )

        log.clear()
        local first_handle = typst_test_compiler(project).watcher.handle
        local restart_handle = typst.compiler.watch()
        local queued_restart_handle = typst.compiler.watch()

        assert(
            restart_handle
                and restart_handle.restart == true
                and restart_handle.stop_handle == first_handle,
            "first restart should return a restart handle tracking the stopping watcher"
        )
        assert(
            queued_restart_handle
                and queued_restart_handle.restart == true
                and queued_restart_handle.stop_handle == first_handle,
            "queued restart should return a restart handle tracking the stopping watcher"
        )

        assert(
            vim.wait(10000, function()
                return typst_test_compiler(project).watcher
                    and typst_test_compiler(project).watcher.handle ~= first_handle
                    and typst_test_compiler(project).watcher.last_cycle_status
                        == "success"
            end, 20),
            "watcher did not restart after queued restart requests"
        )
        assert(
            queued_restart_handle.next_handle
                == typst_test_compiler(project).watcher.handle,
            "queued restart handle should update to the replacement watcher"
        )

        local entries = typst.ui.log()
        local stop_count = 0
        local sigterm_count = 0
        local pending_count = 0
        for _, entry in ipairs(entries) do
            if entry.message == "stopping watcher" then
                stop_count = stop_count + 1
            elseif entry.message == "watcher process SIGTERM sent" then
                sigterm_count = sigterm_count + 1
            elseif entry.message == "watcher restart already pending" then
                pending_count = pending_count + 1
            end
        end

        assert(
            stop_count == 1,
            "queued watch restarts should issue one watcher stop"
        )
        assert(
            sigterm_count == 1,
            "queued watch restarts should issue one watcher SIGTERM"
        )
        assert(
            pending_count >= 1,
            "queued watch restarts should be logged as pending"
        )
        assert(
            #vim.fn.readfile(marker) == 2,
            "queued watch restarts should start exactly one replacement watcher"
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
            "watcher did not stop after restart debounce test"
        )
    end, debug.traceback)

    vim.env.TYPST_NVIM_SLOW_WATCH_MARKER = old_marker
    if not ok then
        error(err)
    end
end)

run_case("restart stop failure preserves watcher", function()
    local compiler = require("typst.compiler.typst")
    local process = require("typst.core.process")
    local project_services = require("typst.project.services")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("watch-restart-failure-output"),
    })

    local handle = {
        pid = 12345,
        is_closing = function()
            return false
        end,
    }

    local project = {
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
    }
    project_services.set_compiler(project, {
        output = typst_test_cache_path("watch-restart-failure-output/main.pdf"),
        status = "watching",
        generation = 0,
        watch_generation = 1,
        watcher = {
            handle = handle,
            generation = 1,
            command = {},
            cwd = root,
            stdout = "",
            stderr = "",
            line_buffers = {},
            cycle = 0,
            currently_compiling = false,
            stopping = false,
        },
    })

    local original_kill = process.kill
    process.kill = function()
        return false, "simulated kill failure"
    end

    local restart_result = nil
    local ok, returned = pcall(function()
        return compiler.start(project, function(result)
            restart_result = result
        end)
    end)
    process.kill = original_kill

    assert(ok, returned)
    assert(
        returned
            and returned.restart == true
            and returned.stop_handle == handle
            and returned.result == restart_result,
        "failed restart should return a restart handle tracking the original watcher"
    )
    assert(
        restart_result and restart_result.stopped == false,
        "failed watcher restart should report the stop failure"
    )
    assert(
        restart_result.error == "simulated kill failure",
        "failed watcher restart should propagate the stop error"
    )
    assert(
        typst_test_compiler(project).status == "error",
        "failed watcher restart should leave the project in an error state"
    )
    assert(
        typst_test_compiler(project).watcher,
        "failed watcher restart should keep the original watcher state"
    )
    assert(
        typst_test_compiler(project).watcher.stopping == false,
        "failed watcher restart should clear the stale stopping flag"
    )
    assert(
        typst_test_compiler(project).watcher.stop_callback == nil,
        "failed watcher restart should clear the stale stop callback"
    )
    assert(
        typst_test_compiler(project).watcher.restart_pending == nil,
        "failed watcher restart should clear the queued restart"
    )
end)

vim.cmd("qa!")
