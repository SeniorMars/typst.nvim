local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local registry = require("typst.project")
local project_store = require("typst.project.store")
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
        "TypstCompilerLifecycle" .. case_id,
        { clear = true }
    )

    cleanup(group)
    group = vim.api.nvim_create_augroup(
        "TypstCompilerLifecycle" .. case_id,
        { clear = true }
    )

    local ok, err = xpcall(function()
        fn(group)
    end, debug.traceback)

    cleanup(group)

    if not ok then
        error(("compiler lifecycle case failed [%s]:\n%s"):format(name, err))
    end
end

local function setup_project(opts)
    typst.reset()
    typst.setup(vim.tbl_extend("force", {
        root = root,
        output_dir = typst_test_cache_path("compiler-lifecycle-output"),
    }, opts or {}))

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    return project, main
end

local function command_arg_after(command, name)
    for index, arg in ipairs(command or {}) do
        if arg == name then
            return command[index + 1]
        end
    end
end

run_case("compile success and parent failure", function(group)
    local project = setup_project({
        output_dir = typst_test_cache_path("test-output"),
    })

    local started_event = nil
    local started_event_process = nil
    local started_event_operation = nil
    local success_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStarted",
        callback = function(args)
            started_event = args.data
            started_event_process = typst_test_compiler(project).process
            started_event_operation =
                typst_test_compiler(project).process_operation
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileSuccess",
        callback = function(args)
            success_event = args.data
        end,
    })

    local done = false
    local result_code = nil
    local deps_path = nil

    local handle = typst.compiler.compile({}, function(result)
        result_code = result.code
        deps_path = result.deps_path
        done = true
    end)
    assert(
        typst_test_compiler(project).process == handle,
        "project should track the active one-shot compile process"
    )
    assert(
        started_event_process == handle,
        "TypstCompileStarted should see the active compile process"
    )
    assert(
        started_event_operation and started_event_operation.handle == handle,
        "TypstCompileStarted should see the active compile operation"
    )

    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        "Typst compile did not finish"
    )
    assert(
        result_code == 0,
        ("expected compile success, got %s"):format(vim.inspect(result_code))
    )
    assert(
        vim.fn.filereadable(typst_test_compiler(project).output) == 1,
        ("missing output %s"):format(typst_test_compiler(project).output)
    )
    assert(
        typst_test_compiler(project).process == nil,
        "project should clear one-shot compile process after success"
    )
    assert(
        deps_path and deps_path ~= "",
        "compile should report the dependency capture path"
    )
    assert(
        vim.fn.filereadable(deps_path) == 0,
        "compile dependency temp file should be removed"
    )
    assert(started_event, "TypstCompileStarted event was not emitted")
    assert(
        started_event.key == project.key,
        "TypstCompileStarted event had wrong key"
    )
    assert(
        started_event.status == "compiling",
        "TypstCompileStarted event had wrong status"
    )
    assert(started_event.cwd == root, "TypstCompileStarted event had wrong cwd")
    assert(
        vim.deep_equal(
            started_event.command,
            typst_test_compiler(project).last_command
        ),
        "TypstCompileStarted event had wrong command"
    )
    assert(success_event, "TypstCompileSuccess event was not emitted")
    assert(
        success_event.status == "success",
        "TypstCompileSuccess event had wrong status"
    )
    assert(success_event.code == 0, "TypstCompileSuccess should include code")
    assert(
        success_event.deps_path == deps_path,
        "TypstCompileSuccess should include deps path"
    )
    assert(
        success_event.stale == false,
        "TypstCompileSuccess should include stale=false"
    )
    assert(
        success_event.output == typst_test_compiler(project).output,
        "TypstCompileSuccess event had wrong output"
    )
    assert(
        vim.deep_equal(
            success_event.command,
            typst_test_compiler(project).last_command
        ),
        "TypstCompileSuccess event had wrong command"
    )

    local util = require("typst.core.util")
    local process = require("typst.core.process")
    local original_ensure_parent = util.ensure_parent
    local original_spawn = process.spawn
    local spawn_count = 0
    local parent_failure = nil

    util.ensure_parent = function()
        return false, "synthetic parent failure"
    end
    process.spawn = function(...)
        spawn_count = spawn_count + 1
        return original_spawn(...)
    end

    local failed_handle = typst.compiler.compile({}, function(result)
        parent_failure = result
    end)

    util.ensure_parent = original_ensure_parent
    process.spawn = original_spawn

    assert(
        failed_handle == nil,
        "parent failure should not return a compile handle"
    )
    assert(spawn_count == 0, "parent failure should not spawn typst")
    assert(
        parent_failure and parent_failure.reason == "parent_create_failed",
        "parent failure should be reported before spawning"
    )
end)

run_case("stop active and idle compile", function(group)
    local executable = helpers.fake_typst_sleep(root)
    local project = setup_project({
        executable = executable,
        output_dir = typst_test_cache_path("compile-stop-output"),
        compile = {
            deps = true,
        },
    })

    local stopped_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStopped",
        callback = function(args)
            stopped_event = args.data
        end,
    })

    local compile_callback_called = false
    local handle = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)

    assert(
        typst_test_compiler(project).process == handle,
        "project should track the running one-shot compile"
    )
    assert(
        typst_test_compiler(project).status == "compiling",
        "project should report compiling before stop"
    )

    local deps_path = assert(
        command_arg_after(typst_test_compiler(project).last_command, "--deps"),
        "compile should request dependency capture"
    )
    vim.fn.writefile({ "{}" }, deps_path)

    local stop_result = nil
    local stopped_handle = typst.compiler.stop({}, function(result)
        stop_result = result
    end)

    assert(
        stopped_handle == handle,
        "TypstStop should return the stopped compile handle"
    )
    assert(
        stop_result == nil,
        "TypstStop callback should wait for the compile process to exit"
    )
    assert(
        vim.fn.filereadable(deps_path) == 1,
        "TypstStop should not finalize dependency cleanup before process exit"
    )
    assert(
        typst_test_compiler(project).process == handle,
        "TypstStop should keep tracking the one-shot compile until it exits"
    )
    assert(
        typst_test_compiler(project).status == "stopping",
        "TypstStop should report stopping until the process exits"
    )

    assert(
        vim.wait(10000, function()
            return handle:is_closing()
                and typst_test_compiler(project).process == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "stopped compile process handle did not close"
    )
    assert(
        stop_result and stop_result.stopped,
        "TypstStop callback should report stopped compile"
    )
    assert(
        stop_result.deps_path == deps_path,
        "TypstStop should report the stopped compile dependency path"
    )
    assert(
        vim.fn.filereadable(deps_path) == 0,
        "TypstStop should remove compile dependency temp files after exit"
    )
    assert(
        stopped_event and stopped_event.key == project.key,
        "TypstCompileStopped event was not emitted"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "stale stopped compile result should not call public compile callback"
    )

    local idle_stopped_event = false
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStopped",
        callback = function()
            idle_stopped_event = true
        end,
    })

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message)
        notifications[#notifications + 1] = message
    end

    local idle_stop_result = nil
    local idle_stop_handle = typst.compiler.stop({}, function(result)
        idle_stop_result = result
    end)

    vim.notify = original_notify

    assert(
        idle_stop_handle == nil,
        "idle TypstStop should not return a process handle"
    )
    assert(
        idle_stop_result and idle_stop_result.stopped,
        "idle TypstStop should keep reporting stopped"
    )
    assert(
        idle_stop_result.idle,
        "idle TypstStop should mark the result as an idle no-op"
    )
    assert(
        not idle_stopped_event,
        "idle TypstStop should not emit another stopped event"
    )
    assert(
        notifications[1]
            and notifications[1]:find("No active Typst compiler", 1, true),
        "idle TypstStop should report that no compiler was active"
    )
    assert(
        not notifications[1]:find("^Stopped "),
        "idle TypstStop should not claim that an active compiler was stopped"
    )
end)

run_case("compile started event handler can stop compile", function(group)
    local executable = helpers.fake_typst_sleep(root)
    local project = setup_project({
        executable = executable,
        output_dir = typst_test_cache_path("compile-start-stop-output"),
        compile = {
            deps = false,
        },
    })

    local started_process = nil
    local started_operation = nil
    local stop_handle = nil
    local stop_result = nil
    local stopped_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStarted",
        callback = function()
            started_process = typst_test_compiler(project).process
            started_operation = typst_test_compiler(project).process_operation
            stop_handle = typst.compiler.stop({}, function(result)
                stop_result = result
            end)
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStopped",
        callback = function(args)
            stopped_event = args.data
        end,
    })

    local compile_callback_called = false
    local handle = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)

    assert(
        started_process == handle,
        "TypstCompileStarted handler should see the active compile process"
    )
    assert(
        started_operation and started_operation.handle == handle,
        "TypstCompileStarted handler should see the active compile operation"
    )
    assert(
        stop_handle and stop_handle.deferred == true,
        "TypstStop from TypstCompileStarted should return a deferred stop proxy"
    )
    assert(
        typst_test_compiler(project).process == handle,
        "TypstStop from TypstCompileStarted should leave active state visible until dispatch settles"
    )

    assert(
        vim.wait(10000, function()
            return handle:is_closing()
                and typst_test_compiler(project).process == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "compile stopped from TypstCompileStarted did not settle"
    )
    assert(
        stop_result and stop_result.stopped,
        "TypstStop callback should report stopped compile"
    )
    assert(
        stopped_event and stopped_event.key == project.key,
        "TypstCompileStopped should fire after start-handler stop"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "compile callback should not receive the stale stopped result"
    )
end)

run_case("restart waits for old compile exit", function(group)
    local marker = typst_test_cache_path("compile-restart-output/slow-stop.txt")
    vim.fn.delete(marker)
    vim.fn.mkdir(vim.fs.dirname(marker), "p")

    local old_marker = vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER
    vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER = marker
    local ok, err = xpcall(function()
        local project = setup_project({
            executable = helpers.python_command(
                root .. "/tests/fixtures/fake-typst-compile-slow-stop.py"
            ),
            output_dir = typst_test_cache_path("compile-restart-output"),
            compile = {
                deps = false,
            },
        })

        local stopped_event_count = 0
        vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = "TypstCompileStopped",
            callback = function()
                stopped_event_count = stopped_event_count + 1
            end,
        })

        local first_callback_called = false
        local first_handle = typst.compiler.compile({}, function()
            first_callback_called = true
        end)

        assert(
            typst_test_compiler(project).process == first_handle,
            "first compile process should be active before restart"
        )
        assert(
            vim.wait(10000, function()
                return vim.fn.filereadable(marker) == 1
                    and #vim.fn.readfile(marker) >= 1
            end, 20),
            "first compile process did not record startup"
        )

        local second_callback_called = false
        local second_handle = typst.compiler.compile({}, function()
            second_callback_called = true
        end)

        assert(
            second_handle
                and second_handle.restart == true
                and second_handle.stop_handle == first_handle,
            "restarted compile should return a restart handle tracking the stopping process"
        )
        assert(
            typst_test_compiler(project).process == first_handle,
            "project should keep tracking the old compile until it exits"
        )
        assert(
            typst_test_compiler(project).status == "stopping",
            "project should report stopping while waiting for the old compile"
        )
        assert(
            stopped_event_count == 0,
            "compile restart should not emit stopped before the process exits"
        )

        vim.wait(100, function()
            return false
        end, 20)
        assert(
            typst_test_compiler(project).process == first_handle,
            "replacement compile should not start during the SIGTERM grace window"
        )
        assert(
            #vim.fn.readfile(marker) == 2,
            "replacement compile should not start before the old compile exits"
        )

        assert(
            vim.wait(10000, function()
                return first_handle:is_closing()
                    and typst_test_compiler(project).process
                    and typst_test_compiler(project).process ~= first_handle
                    and #vim.fn.readfile(marker) >= 4
            end, 20),
            "replacement compile did not start after cancelled compile exited"
        )

        assert(
            stopped_event_count == 1,
            "compile restart should emit one stopped event after the old compile exits"
        )
        local second_started_handle = typst_test_compiler(project).process
        assert(
            second_handle.next_handle == second_started_handle,
            "restart handle should update to the replacement compile process"
        )
        assert(
            second_started_handle ~= first_handle,
            "project should track a replacement compile process"
        )
        assert(
            typst_test_compiler(project).status == "compiling",
            "project should compile after the old process exits"
        )
        local marker_lines = vim.fn.readfile(marker)
        assert(
            marker_lines[3]:match("^exit:"),
            "old compile exit should be recorded before replacement start"
        )
        assert(
            marker_lines[4]:match("^start:"),
            "replacement compile should start after old compile exit is recorded"
        )

        vim.wait(200, function()
            return first_callback_called or second_callback_called
        end, 20)
        assert(
            not first_callback_called,
            "cancelled compile callback should remain stale after restart"
        )
        assert(
            not second_callback_called,
            "replacement compile callback should wait for its process result"
        )

        typst.compiler.stop()

        assert(
            vim.wait(10000, function()
                return typst_test_compiler(project).process == nil
                    and second_started_handle:is_closing()
                    and typst_test_compiler(project).status == "idle"
            end, 20),
            "replacement compile did not stop cleanly after restart test"
        )
    end, debug.traceback)
    vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER = old_marker
    if not ok then
        error(err)
    end
end)

run_case("cancel pending compile restart", function()
    local marker = typst_test_cache_path("compile-restart-cancel/slow-stop.txt")
    vim.fn.delete(marker)
    vim.fn.mkdir(vim.fs.dirname(marker), "p")

    local old_marker = vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER
    vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER = marker
    local ok, err = xpcall(function()
        local project = setup_project({
            executable = helpers.python_command(
                root .. "/tests/fixtures/fake-typst-compile-slow-stop.py"
            ),
            output_dir = typst_test_cache_path("compile-restart-cancel-output"),
            compile = {
                deps = false,
            },
        })

        local first_handle = typst.compiler.compile()
        assert(
            vim.wait(10000, function()
                return vim.fn.filereadable(marker) == 1
                    and #vim.fn.readfile(marker) >= 1
            end, 20),
            "first compile process did not start before cancellation test"
        )

        local restart = typst.compiler.compile()
        assert(
            restart
                and restart.restart == true
                and restart.stop_handle == first_handle,
            "compile restart should return a restart handle before cancellation"
        )

        restart.cancel({ reason = "manual_cancel" })
        assert(
            restart.pending == false and restart.cancel_requested == true,
            "cancel should finish and mark the restart handle"
        )

        assert(
            vim.wait(10000, function()
                local compiler = typst_test_compiler(project)
                return first_handle:is_closing()
                    and compiler.process == nil
                    and compiler.status == "idle"
            end, 20),
            "old compile did not finish after cancelled restart"
        )

        local starts = 0
        for _, line in ipairs(vim.fn.readfile(marker)) do
            if line:match("^start:") then
                starts = starts + 1
            end
        end
        assert(
            starts == 1,
            "cancelled compile restart should not launch a replacement compile"
        )
    end, debug.traceback)
    vim.env.TYPST_NVIM_SLOW_COMPILE_MARKER = old_marker
    if not ok then
        error(err)
    end
end)

run_case("detach stops active compile", function()
    local project = setup_project({
        executable = helpers.fake_typst_sleep(root),
        output_dir = typst_test_cache_path("compile-detach-output"),
        compile = {
            deps = false,
        },
    })

    local compile_callback_called = false
    local handle = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)
    local live_project = assert(project_store.get(project.key))

    assert(
        typst_test_compiler(project).process == handle,
        "project should track the running one-shot compile before detach"
    )
    assert(
        project_store.all()[project.key] == live_project,
        "project should be registered before detach"
    )

    vim.cmd("bdelete")

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).process == nil
                and typst_test_compiler(project).status == "idle"
                and project_store.all()[project.key] == nil
                and handle:is_closing()
        end, 20),
        "last buffer detach should stop the active one-shot compile and prune the project"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "stale detached compile result should not call public compile callback"
    )
end)

run_case("compile stops active watcher", function(group)
    local project = setup_project({
        executable = helpers.fake_typst_sleep(root),
        output_dir = typst_test_cache_path("compile-stops-watch-output"),
        compile = {
            deps = false,
        },
    })

    local watch_handle = typst.compiler.watch()
    assert(
        typst_test_compiler(project).watcher
            and typst_test_compiler(project).watcher.handle == watch_handle,
        "watcher should be active before compile starts"
    )

    local stopped_event_count = 0
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStopped",
        callback = function()
            stopped_event_count = stopped_event_count + 1
        end,
    })

    local compile_callback_called = false
    local returned_handle = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)

    assert(
        returned_handle
            and returned_handle.restart == true
            and returned_handle.stop_handle == watch_handle,
        "compile should return a restart handle tracking the watcher stop"
    )

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).process ~= nil
                and typst_test_compiler(project).status == "compiling"
        end, 20),
        "compile should stop the active watcher before starting a one-shot compile"
    )
    assert(
        returned_handle.next_handle == typst_test_compiler(project).process,
        "compile restart handle should update to the replacement process"
    )

    assert(
        stopped_event_count == 1,
        "starting compile should emit a stopped event for the cancelled watcher"
    )
    assert(
        watch_handle:is_closing(),
        "cancelled watcher handle did not close after compile started"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "compile callback should wait for the replacement one-shot compile result"
    )

    local compile_handle = typst_test_compiler(project).process
    typst.compiler.stop()

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).process == nil
                and compile_handle:is_closing()
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "replacement one-shot compile did not stop cleanly"
    )
end)

run_case("watch stops active compile", function(group)
    local project = setup_project({
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-compile-slow-stop.py"
        ),
        output_dir = typst_test_cache_path("watch-stops-compile-output"),
        compile = {
            deps = false,
        },
    })

    local compile_callback_called = false
    local compile_handle = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)
    assert(
        typst_test_compiler(project).process == compile_handle,
        "compile process should be active before watch starts"
    )

    local stopped_event_count = 0
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStopped",
        callback = function()
            stopped_event_count = stopped_event_count + 1
        end,
    })

    local watch_handle = typst.compiler.watch()
    assert(
        watch_handle
            and watch_handle.restart == true
            and watch_handle.stop_handle == compile_handle,
        "watch should return a restart handle tracking the stopping compile"
    )
    assert(
        typst_test_compiler(project).process == compile_handle,
        "watch should keep tracking the previous compile until it exits"
    )
    assert(
        typst_test_compiler(project).watcher == nil,
        "watcher should not start before the compile process exits"
    )
    assert(
        typst_test_compiler(project).status == "stopping",
        "project should report stopping while waiting for compile exit"
    )
    assert(
        stopped_event_count == 0,
        "starting watch should not emit stopped before compile exit"
    )

    assert(
        vim.wait(10000, function()
            return compile_handle:is_closing()
                and typst_test_compiler(project).process == nil
                and typst_test_compiler(project).watcher ~= nil
        end, 20),
        "watcher did not start after cancelled compile exited"
    )
    assert(
        watch_handle.next_handle == typst_test_compiler(project).watcher.handle,
        "watch restart handle should update to the replacement watcher"
    )

    assert(
        typst_test_compiler(project).status == "watching",
        "project should report watching after watch starts"
    )
    assert(
        stopped_event_count == 1,
        "starting watch should emit a stopped event after compile exit"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "cancelled compile callback should remain stale after watch starts"
    )

    typst.compiler.stop()
    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "watcher did not stop cleanly after race test"
    )
end)

vim.cmd("qa!")
