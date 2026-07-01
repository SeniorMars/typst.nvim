local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local output_ownership = require("typst.resources.outputs")
local compiler_service = require("typst.project.services.compiler")
local project_facade = require("typst.project")
local project_registry = require("typst.project.registry")
local project_services = require("typst.project.services")

local callbacks = {}

local provider = {
    name = "async-provider",
    compile = function(project, callback, run_config)
        callbacks.compile = callback
        typst_test_compiler(project).last_command = {
            "async-provider",
            "compile",
            project.main,
            run_config.compile.profile,
        }
        typst_test_compiler(project).last_cwd = project.root
        return { kind = "compile", pid = 5101 }
    end,
    start = function(project, callback, run_config)
        callbacks.watch = callback
        typst_test_compiler(project).last_command = {
            "async-provider",
            "watch",
            project.main,
            run_config.compile.profile,
        }
        typst_test_compiler(project).last_cwd = project.root
        return { kind = "watch", pid = 5102 }
    end,
    stop = function(_project, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
        return { kind = "stop", pid = 5103 }
    end,
    status = function(project)
        return "async-" .. typst_test_compiler(project).status
    end,
    output = function(_project, run_config)
        return typst_test_cache_path("async-provider/")
            .. (run_config.compile.profile or "default")
            .. ".pdf"
    end,
}

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    compile = {
        provider = provider,
        profiles = {
            custom = {},
        },
    },
})

local function make_force_clear_collision(prefix)
    local literal_key = prefix .. "%2Fmain"
    local decoded_key = prefix .. "/main"
    local literal_project = {
        key = literal_key,
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        services = project_services.new_state(),
        compiler_provider = {
            provider = { name = "literal-collision-provider" },
            external = true,
        },
    }
    local decoded_project = {
        key = decoded_key,
        root = root,
        main = root .. "/tests/fixtures/basic/chapter.typ",
        services = project_services.new_state(),
        compiler_provider = {
            provider = { name = "decoded-collision-provider" },
            external = true,
        },
    }
    local literal_output =
        typst_test_cache_path(prefix .. "-literal-output.pdf")
    local decoded_output =
        typst_test_cache_path(prefix .. "-decoded-output.pdf")
    local literal_lease = assert(
        output_ownership.acquire(
            literal_output,
            output_ownership.owner("collision-literal", literal_project)
        )
    )
    local decoded_lease = assert(
        output_ownership.acquire(
            decoded_output,
            output_ownership.owner("collision-decoded", decoded_project)
        )
    )

    project_registry.set(literal_key, literal_project)
    project_registry.set(decoded_key, decoded_project)
    compiler_service.set(literal_project, {
        process = { kind = "literal-collision" },
        output = literal_output,
        output_lease = literal_lease,
        status = "stopping_failed",
    })
    compiler_service.set(decoded_project, {
        process = { kind = "decoded-collision" },
        output = decoded_output,
        output_lease = decoded_lease,
        status = "stopping_failed",
    })

    return {
        literal_key = literal_key,
        decoded_key = decoded_key,
        literal_project = literal_project,
        decoded_project = decoded_project,
        literal_output = literal_output,
        decoded_output = decoded_output,
        literal_lease = literal_lease,
        decoded_lease = decoded_lease,
    }
end

local function cleanup_collision(collision)
    if not collision then
        return
    end
    output_ownership.release(collision.literal_lease)
    output_ownership.release(collision.decoded_lease)
    project_registry.remove(collision.literal_key)
    project_registry.remove(collision.decoded_key)
end

vim.cmd.enew()
local no_project_clear = typst.compiler.force_clear({ notify = false })
assert(
    no_project_clear.reason == "no_project",
    "force clear outside a Typst project should return no_project"
)
local no_project_command_ok, no_project_command_err =
    pcall(vim.cmd, "TypstCompilerForceClear")
assert(
    no_project_command_ok,
    "TypstCompilerForceClear outside a Typst project should not throw: "
        .. tostring(no_project_command_err)
)

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local events = {}
for _, name in ipairs({
    "TypstCompileStarted",
    "TypstCompileSuccess",
    "TypstCompileFailed",
    "TypstCompileStopped",
}) do
    vim.api.nvim_create_autocmd("User", {
        pattern = name,
        callback = function(args)
            events[#events + 1] = {
                name = name,
                data = args.data,
            }
        end,
    })
end

local compile_callback = nil
local compile_handle = typst.compiler.compile(
    { profile = "custom" },
    function(result)
        compile_callback = result
    end
)

assert(
    compile_handle.kind == "compile",
    "async custom compile handle was not returned"
)
assert(
    typst_test_compiler(project).process == compile_handle,
    "async custom compile handle should be tracked while active"
)
assert(
    typst_test_compiler(project).status == "compiling",
    "async custom compile should remain active before callback"
)
assert(
    compile_callback == nil,
    "async compile callback should wait for provider result"
)
assert(
    events[1] and events[1].name == "TypstCompileStarted",
    "async compile should emit started"
)
assert(
    events[1].data.status == "compiling",
    "async compile started event should expose compiling status"
)

callbacks.compile({ code = 0, stale = false })
assert(
    compile_callback and compile_callback.code == 0,
    "async compile callback should receive provider result"
)
assert(
    typst_test_compiler(project).process == nil,
    "async custom compile result should clear the active process handle"
)
assert(
    typst_test_compiler(project).status == "success",
    "async custom compile success should update project status"
)
assert(
    typst.ui.status().status == "async-success",
    "status() should expose async provider compile status"
)
assert(
    events[2] and events[2].name == "TypstCompileSuccess",
    "async compile should emit success"
)
assert(
    events[2].data.status == "success",
    "async compile success event should expose final status"
)

local watch_callback = nil
local watch_handle = typst.compiler.watch(
    { profile = "custom" },
    function(result)
        watch_callback = result
    end
)

assert(
    watch_handle.kind == "watch",
    "async custom watch handle was not returned"
)
assert(
    typst_test_compiler(project).watcher == watch_handle,
    "async custom watch handle should be tracked while active"
)
assert(
    typst_test_compiler(project).status == "watching",
    "async custom watch should report watching before callback"
)
assert(
    watch_callback == nil,
    "async watch callback should wait for provider result"
)
assert(
    events[3] and events[3].name == "TypstCompileStarted",
    "async watch should emit started"
)
assert(
    events[3].data.status == "starting",
    "async watch started event should expose starting status"
)

callbacks.watch({ code = 1, stale = false })
assert(
    watch_callback and watch_callback.code == 1,
    "async watch callback should receive provider failure"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "async custom watch failure should clear the active watcher handle"
)
assert(
    typst_test_compiler(project).status == "error",
    "async custom watch failure should update project status"
)
assert(
    typst.ui.status().status == "async-error",
    "status() should expose async provider watch failure"
)
assert(
    events[4] and events[4].name == "TypstCompileFailed",
    "async watch failure should emit failed"
)
assert(
    events[4].data.status == "error",
    "async watch failed event should expose final status"
)

typst.compiler.watch({ profile = "custom" })
assert(
    typst_test_compiler(project).watcher
        and typst_test_compiler(project).watcher.kind == "watch",
    "async custom watch should start again after failure"
)
typst.compiler.stop()
assert(
    typst_test_compiler(project).watcher == nil,
    "async custom stop should clear watcher handle"
)
assert(
    typst_test_compiler(project).status == "idle",
    "async custom stop should return project to idle"
)
assert(
    typst.ui.status().status == "async-idle",
    "status() should expose async provider stopped status"
)
assert(
    events[6] and events[6].name == "TypstCompileStopped",
    "async custom stop should emit stopped"
)
assert(
    events[6].data.status == "idle",
    "async custom stopped event should expose final status"
)

local timeout_provider = {
    name = "timeout-provider",
    compile = function()
        return { kind = "compile-timeout" }
    end,
    start = function()
        return { kind = "watch-timeout" }
    end,
    stop = function()
        return { kind = "stop-timeout" }
    end,
    status = function(project)
        return "timeout-" .. typst_test_compiler(project).status
    end,
    output = function()
        return typst_test_cache_path("async-provider/timeout.pdf")
    end,
}

typst.reset()
typst.setup({
    root = root,
    compile = {
        provider = timeout_provider,
        provider_timeout_ms = 20,
    },
})
vim.cmd.edit(main)
project = typst.project.set_main(main)

local timeout_compile = nil
local timeout_compile_handle = typst.compiler.compile({}, function(result)
    timeout_compile = result
end)
assert(
    timeout_compile_handle and timeout_compile_handle.kind == "compile-timeout",
    "raw compile timeout handle should be returned"
)
assert(
    vim.wait(1000, function()
        return timeout_compile ~= nil
    end, 10),
    "raw compile handle should time out"
)
assert(
    timeout_compile.reason == "timeout" and timeout_compile.code == 1,
    "raw compile timeout should be normalized as a failure"
)
assert(
    typst_test_compiler(project).process == timeout_compile_handle,
    "raw compile timeout should retain the unconfirmed active process"
)
assert(
    typst_test_compiler(project).status == "stopping_failed",
    "raw compile timeout should mark compiler state as stopping_failed"
)
assert(
    timeout_compile.status == "stopping_failed",
    "raw compile timeout callback should expose stopping_failed status"
)
assert(
    typst_test_compiler(project).output_lease
        and output_ownership.active(timeout_provider.output()),
    "raw compile timeout should retain the output lease"
)
local unknown_clear =
    typst.compiler.force_clear({ key = "not-a-project-key", notify = false })
assert(
    not unknown_clear.ok
        and unknown_clear.reason == "unknown_project_key"
        and unknown_clear.key == "not-a-project-key"
        and unknown_clear.key_display == "not-a-project-key",
    "force clear with an unknown key should fail without falling back and return command keys"
)
assert(
    typst_test_compiler(project).process == timeout_compile_handle
        and output_ownership.active(timeout_provider.output()),
    "unknown keyed force clear should not clear the current project"
)
local original_notify = vim.notify
local unknown_command_notifications = {}
vim.notify = function(message, level)
    unknown_command_notifications[#unknown_command_notifications + 1] = {
        message = message,
        level = level,
    }
end
local unknown_command_ok, unknown_command_err =
    pcall(vim.cmd, "TypstCompilerForceClear! not-a-project-key")
vim.notify = original_notify
assert(
    unknown_command_ok,
    "TypstCompilerForceClear unknown key should not throw: "
        .. tostring(unknown_command_err)
)
assert(
    unknown_command_notifications[1]
        and unknown_command_notifications[1].level == vim.log.levels.ERROR,
    "TypstCompilerForceClear unknown key should notify as an error"
)
assert(
    typst_test_compiler(project).process == timeout_compile_handle
        and output_ownership.active(timeout_provider.output()),
    "TypstCompilerForceClear unknown key should not clear the current project"
)

local collision = make_force_clear_collision("force-clear-collision-lua")
local ambiguous_clear = typst.compiler.force_clear({
    key = project_registry.encode_key(collision.decoded_key),
    notify = false,
})
assert(
    not ambiguous_clear.ok and ambiguous_clear.reason == "ambiguous_project_key",
    "Lua force_clear should fail closed when raw and encoded keys collide"
)
assert(
    output_ownership.active(collision.literal_output)
        and output_ownership.active(collision.decoded_output),
    "ambiguous Lua force_clear should not release either colliding output lease"
)
local project_object_clear = typst.compiler.force_clear({
    project = collision.decoded_project,
    key = collision.literal_key,
    notify = false,
})
assert(
    project_object_clear.ok
        and project_object_clear.key == collision.decoded_key,
    "Lua force_clear should let explicit project objects override conflicting key strings"
)
assert(
    output_ownership.active(collision.literal_output)
        and not output_ownership.active(collision.decoded_output),
    "project-object force_clear should clear only the explicit project"
)
cleanup_collision(collision)

collision = make_force_clear_collision("force-clear-collision-command")
local encoded_command_key = project_registry.encode_key(collision.decoded_key)
assert(
    encoded_command_key == collision.literal_key,
    "collision fixture should make decoded key's command display match another raw key"
)
local command_collision_ok, command_collision_err =
    pcall(vim.cmd, "TypstCompilerForceClear! " .. encoded_command_key)
assert(
    command_collision_ok,
    "TypstCompilerForceClear should accept encoded colliding key: "
        .. tostring(command_collision_err)
)
assert(
    output_ownership.active(collision.literal_output)
        and not output_ownership.active(collision.decoded_output),
    "TypstCompilerForceClear should resolve encoded project keys before raw collisions"
)
cleanup_collision(collision)

local force_clear_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompilerForceCleared",
    callback = function(args)
        force_clear_event = args.data
    end,
    once = true,
})
local compile_timeout_clear =
    typst.compiler.force_clear({ key = project.key, notify = false })
assert(
    compile_timeout_clear.ok
        and compile_timeout_clear.discarded == true
        and compile_timeout_clear.forced == false,
    "force clear by key should discard compile timeout state"
)
assert(
    compile_timeout_clear.key == project.key
        and compile_timeout_clear.key_display
            == project_registry.encode_key(project.key),
    "force clear result should include raw and command-safe project keys"
)
assert(
    force_clear_event
        and force_clear_event.reason == "force_cleared"
        and force_clear_event.stopped == false
        and force_clear_event.forced == false
        and force_clear_event.key == project.key
        and force_clear_event.key_display
            == compile_timeout_clear.key_display,
    "force clear should emit a destructive recovery event with project keys"
)

local timeout_watch = nil
local timeout_watch_handle = typst.compiler.watch({}, function(result)
    timeout_watch = result
end)
assert(
    timeout_watch_handle and timeout_watch_handle.kind == "watch-timeout",
    "raw watch timeout handle should be returned"
)
assert(
    vim.wait(1000, function()
        return timeout_watch ~= nil
    end, 10),
    "raw watch handle should time out"
)
assert(
    timeout_watch.reason == "timeout" and timeout_watch.code == 1,
    "raw watch timeout should be normalized as a failure"
)
assert(
    typst_test_compiler(project).watcher == timeout_watch_handle,
    "raw watch timeout should retain the unconfirmed active watcher"
)
assert(
    typst_test_compiler(project).status == "stopping_failed",
    "raw watch timeout should mark compiler state as stopping_failed"
)
assert(
    timeout_watch.status == "stopping_failed",
    "raw watch timeout callback should expose stopping_failed status"
)
assert(
    typst_test_compiler(project).output_lease
        and output_ownership.active(timeout_provider.output()),
    "raw watch timeout should retain the output lease"
)
local watch_timeout_clear =
    typst.compiler.force_clear({ key = project.key, notify = false })
assert(
    watch_timeout_clear.ok and watch_timeout_clear.discarded == true,
    "force clear by key should discard watch timeout state"
)

typst.reset()
typst.setup({
    root = root,
    compile = {
        provider = timeout_provider,
        provider_timeout_ms = 0,
    },
})
vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(typst.compiler.watch(), "watch should start before stop timeout test")
assert(
    typst_test_compiler(project).watcher ~= nil,
    "watcher should be active before stop timeout test"
)
local premature_clear = typst.compiler.force_clear()
assert(
    not premature_clear.ok and premature_clear.reason == "not_stopping_failed",
    "force clear should refuse active providers before stop failure"
)
assert(
    typst_test_compiler(project).watcher ~= nil,
    "refused force clear should leave active watcher"
)
assert(
    output_ownership.active(timeout_provider.output()),
    "refused force clear should keep the output lease"
)
local forced_active_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompilerForceCleared",
    callback = function(args)
        forced_active_event = args.data
    end,
    once = true,
})
local forced_active_clear = typst.compiler.force_clear({
    force = true,
    notify = false,
})
assert(
    forced_active_clear.ok
        and forced_active_clear.reason == "force_cleared"
        and forced_active_clear.forced == true,
    "bang force clear should mark guard-bypass force"
)
assert(
    forced_active_event
        and forced_active_event.reason == "force_cleared"
        and forced_active_event.forced == true,
    "force-clear event should report whether the guard was bypassed"
)
assert(
    not output_ownership.active(timeout_provider.output()),
    "bang force clear should release active provider output lease"
)
typst.reset()
typst.setup({
    root = root,
    compile = {
        provider = timeout_provider,
        provider_timeout_ms = 0,
    },
})
vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(typst.compiler.watch(), "watch should restart before stop timeout test")
assert(
    typst_test_compiler(project).watcher ~= nil,
    "watcher should be active before stop timeout test after forced clear"
)
typst.setup({
    root = root,
    compile = {
        provider = timeout_provider,
        provider_timeout_ms = 20,
    },
})
local timeout_stop = nil
local stop_timeout_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileFailed",
    callback = function(args)
        stop_timeout_event = args.data
    end,
    once = true,
})
local timeout_stop_handle = typst.compiler.stop({}, function(result)
    timeout_stop = result
end)
assert(
    timeout_stop_handle and timeout_stop_handle.kind == "stop-timeout",
    "raw stop timeout handle should be returned"
)
assert(
    vim.wait(1000, function()
        return timeout_stop ~= nil
    end, 10),
    "raw stop handle should time out"
)
assert(
    timeout_stop.reason == "timeout" and timeout_stop.code == 1,
    "raw stop timeout should be normalized as a failure"
)
assert(
    typst_test_compiler(project).watcher ~= nil,
    "raw stop timeout should retain the unconfirmed active watcher"
)
assert(
    typst_test_compiler(project).status == "stopping_failed",
    "raw stop timeout should mark compiler stop as failed"
)
assert(
    stop_timeout_event and stop_timeout_event.status == "stopping_failed",
    "stop timeout event should expose stopping_failed status"
)
assert(
    typst_test_compiler(project).output_lease
        and output_ownership.active(timeout_provider.output()),
    "raw stop timeout should retain the output lease"
)
local retained_key = project.key
local retained_display_key = project_registry.encode_key(retained_key)
assert(
    retained_display_key ~= retained_key,
    "retained project fixture should require a command-safe display key"
)
local retained_bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(retained_bufnr)
assert(
    project_facade.all()[retained_key] == project,
    "retained output lease should keep bufferless project registered"
)
local force_cleared = typst.compiler.force_clear({
    key = retained_display_key,
    key_encoded = true,
})
assert(force_cleared.ok, "force clear should succeed after stop timeout")
assert(
    force_cleared.reason == "force_cleared" and force_cleared.stopped == false,
    "force clear should not claim provider shutdown"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "force clear should discard the retained watcher handle"
)
assert(
    typst_test_compiler(project).output_lease == nil
        and not output_ownership.active(timeout_provider.output()),
    "force clear should release the retained output lease"
)
assert(
    typst_test_compiler(project).status == "idle",
    "force clear should return compiler status to idle"
)
assert(
    project_facade.all()[retained_key] == nil,
    "force clear should allow a bufferless retained project to prune"
)

for _, case in ipairs({
    {
        reason = "provider_error",
        output = typst_test_cache_path(
            "async-provider/stop-provider-error.pdf"
        ),
    },
    {
        reason = "strange_failure",
        output = typst_test_cache_path(
            "async-provider/stop-unknown-reason.pdf"
        ),
    },
}) do
    local stop_failure_provider = {
        name = "stop-failure-provider-" .. case.reason,
        compile = function()
            return { code = 0, stale = false }
        end,
        start = function()
            return { kind = "watch-" .. case.reason }
        end,
        stop = function(_project, callback)
            callback({
                ok = false,
                code = 1,
                stale = false,
                stopped = false,
                reason = case.reason,
            })
            return { kind = "stop-" .. case.reason }
        end,
        status = function()
            return "watching"
        end,
        output = function()
            return case.output
        end,
    }

    typst.reset()
    typst.setup({
        root = root,
        compile = {
            provider = stop_failure_provider,
            provider_timeout_ms = 200,
        },
    })
    vim.cmd.edit(main)
    project = typst.project.set_main(main)
    local started = typst.compiler.watch()
    assert(started and started.kind == "watch-" .. case.reason)
    local stop_result = nil
    typst.compiler.stop({}, function(result)
        stop_result = result
    end)
    assert(
        stop_result
            and stop_result.reason == case.reason
            and stop_result._typst_unconfirmed_stop == true,
        "stopped=false provider stop failure should be flagged unconfirmed"
    )
    assert(
        typst_test_compiler(project).watcher == started,
        "stopped=false provider stop failure should retain watcher for "
            .. case.reason
    )
    assert(
        typst_test_compiler(project).status == "stopping_failed",
        "stopped=false provider stop failure should mark stopping_failed for "
            .. case.reason
    )
    assert(
        typst.compiler.status() == "stopping_failed",
        "compiler.status should prefer internal stopping_failed over provider status"
    )
    local _, status_lines = typst.ui.status_all({ echo = false })
    local status_text = table.concat(status_lines, "\n")
    assert(
        status_text:find("stopping_failed", 1, true)
            and status_text:find(":TypstCompilerForceClear!", 1, true),
        "status_all should expose force-clear recovery when provider still reports watching"
    )
    assert(
        output_ownership.active(case.output),
        "stopped=false provider stop failure should retain output lease for "
            .. case.reason
    )
    local clear = typst.compiler.force_clear({ notify = false })
    assert(
        clear.ok and clear.reason == "force_cleared",
        "force clear should recover retained stop failure for " .. case.reason
    )
end

vim.cmd("qa!")
