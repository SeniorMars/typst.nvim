local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local calls = {}
local output_profiles = {}
local watch_callback = nil

local provider = {
    name = "test-provider",
    compile = function(project, callback, run_config)
        calls[#calls + 1] =
            { method = "compile", profile = run_config.compile.profile }
        assert(
            typst_test_compiler(project).output:match(
                "provider%-output/custom%.pdf$"
            ),
            "provider output should be resolved before compile"
        )
        typst_test_compiler(project).last_command = {
            "test-provider",
            "compile",
            project.main,
            typst_test_compiler(project).output,
        }
        typst_test_compiler(project).last_cwd = project.root
        typst_test_compiler(project).last_profile = run_config.compile.profile
        callback({ code = 0, stale = false })
        return nil
    end,
    start = function(project, callback, run_config)
        calls[#calls + 1] =
            { method = "start", profile = run_config.compile.profile }
        assert(
            typst_test_compiler(project).output:match(
                "provider%-output/custom%.pdf$"
            ),
            "provider output should be resolved before watch"
        )
        typst_test_compiler(project).last_profile = run_config.compile.profile
        watch_callback = callback
        return { provider = "test", pending = true }
    end,
    stop = function(project, callback)
        calls[#calls + 1] = { method = "stop" }
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
        return nil
    end,
    status = function(project)
        return "provider-" .. typst_test_compiler(project).status
    end,
    output = function(project, run_config)
        local profile = run_config
                and run_config.compile
                and run_config.compile.profile
            or "default"
        output_profiles[#output_profiles + 1] = profile
        return typst_test_cache_path("provider-output/") .. profile .. ".pdf"
    end,
}

local replacement_provider = {
    name = "replacement-provider",
    compile = function()
        error(
            "replacement provider should not compile an active old-provider watcher"
        )
    end,
    start = function()
        error(
            "replacement provider should not start during active-provider stop"
        )
    end,
    stop = function()
        error(
            "replacement provider should not stop an active old-provider watcher"
        )
    end,
    status = function()
        return "replacement-status"
    end,
    output = function()
        return typst_test_cache_path("replacement-provider/output.pdf")
    end,
}

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    compile = {
        provider = provider,
        profiles = {
            custom = {
                output_dir = typst_test_cache_path("provider-profile"),
            },
        },
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local events = {}
for _, name in ipairs({
    "TypstCompileStarted",
    "TypstCompileSuccess",
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

local compile_done = false
local handle = typst.compiler.compile({ profile = "custom" }, function(result)
    assert(result.code == 0, "custom provider compile failed")
    compile_done = true
end)
assert(
    handle and handle.code == 0,
    "custom provider compile should return the synchronous terminal result"
)
assert(compile_done, "custom provider compile callback did not run")
assert(calls[1].method == "compile", "custom compile provider was not used")
assert(
    calls[1].profile == "custom",
    "custom compile provider did not receive profile config"
)
assert(
    typst_test_compiler(project).last_profile == "custom",
    "custom provider should record profile on the project"
)
assert(
    typst_test_compiler(project).output:match("provider%-output/custom%.pdf$"),
    typst_test_compiler(project).output
)
assert(
    typst_test_compiler(project).process == nil,
    "custom compile wrapper should clear returned handles after synchronous success"
)
assert(
    events[1] and events[1].name == "TypstCompileStarted",
    "custom compile should emit started event"
)
assert(
    events[1].data.provider == "test-provider",
    "custom compile started event should expose provider"
)
assert(
    events[1].data.profile == "custom",
    "custom compile started event should expose profile"
)
assert(
    events[1].data.output:match("provider%-output/custom%.pdf$"),
    "custom compile started event should expose provider output"
)
assert(
    events[1].data.status == "compiling",
    "custom compile started event should expose starting status"
)
assert(
    events[2] and events[2].name == "TypstCompileSuccess",
    "custom compile should emit success event"
)
assert(
    events[2].data.status == "success",
    "custom compile success event should expose final status"
)
assert(
    output_profiles[1] == "custom",
    "custom compile should resolve provider output with run profile"
)
assert(
    typst.ui.status().status == "provider-success",
    "status() should use the custom provider status method"
)
assert(
    typst_test_compiler(project).last_result
        and typst_test_compiler(project).last_result.code == 0,
    "custom provider terminal result should be recorded"
)

local captured = {}
local original_echo = vim.api.nvim_echo
rawset(vim.api, "nvim_echo", function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end)

local info_ok, info_err = pcall(function()
    typst.ui.info()
end)
vim.api.nvim_echo = original_echo
assert(info_ok, info_err)
local info_text = table.concat(captured, "\n")
assert(
    info_text:find("provider:%s+test%-provider"),
    "TypstInfo should expose the configured compiler provider"
)
assert(
    info_text:find("status:%s+provider%-success"),
    "TypstInfo should expose custom provider status"
)

local watcher = typst.compiler.watch({ profile = "custom" })
assert(watcher.provider == "test", "custom provider watcher was not returned")
assert(calls[2].method == "start", "custom watch provider was not used")
assert(
    calls[2].profile == "custom",
    "custom watch provider did not receive profile config"
)
assert(
    typst_test_compiler(project).status == "watching",
    "custom provider wrapper should update watcher status"
)
assert(
    typst_test_compiler(project).watcher == watcher,
    "custom provider wrapper should track returned watcher handle"
)
assert(
    typst.ui.status().status == "provider-watching",
    "status() should expose custom provider watcher status"
)
assert(
    events[3] and events[3].name == "TypstCompileStarted",
    "custom watch should emit started event"
)
assert(
    events[3].data.status == "starting",
    "custom watch started event should expose starting status"
)
assert(
    events[3].data.output:match("provider%-output/custom%.pdf$"),
    "custom watch started event should expose provider output"
)
assert(
    type(watch_callback) == "function",
    "custom watch should receive callback"
)
watch_callback({ code = 0, stale = false, watch = true })
assert(
    typst_test_compiler(project).watcher == watcher,
    "custom provider watch cycles should keep the watcher active"
)
assert(
    typst_test_compiler(project).output_lease ~= nil,
    "custom provider watch cycles should keep the output lease active"
)
assert(
    typst_test_compiler(project).status == "watching",
    "custom provider watch cycles should leave the project watching"
)
assert(
    typst_test_compiler(project).last_result
        and typst_test_compiler(project).last_result.watch == true,
    "custom provider watch cycles should be recorded as watch results"
)
assert(
    events[4] and events[4].name == "TypstCompileSuccess",
    "custom provider watch cycle should emit a success event"
)
assert(
    events[4].data.status == "success",
    "custom provider watch cycle success should report success status"
)
assert(
    events[4].data.watch_status == "watching",
    "custom provider watch cycle success should preserve watcher status separately"
)
local provider_collision = typst.artifact.export({
    format = "pdf",
    output_dir = typst_test_cache_path("provider-output"),
    output_name = "custom.pdf",
})
assert(
    not provider_collision.ok and provider_collision.reason == "active_output",
    "custom provider output should be reserved against export collisions"
)

typst.setup({
    root = root,
    compile = {
        provider = replacement_provider,
    },
})
assert(
    typst.ui.status().status == "provider-watching",
    "status() should keep using the provider bound to the active watcher"
)

typst.compiler.stop()
assert(calls[3].method == "stop", "custom stop provider was not used")
assert(
    typst_test_compiler(project).status == "idle",
    "custom provider wrapper should stop cleanly"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "custom provider wrapper should clear watcher on stop"
)

typst.setup({
    root = root,
    compile = {
        provider = provider,
        profiles = {
            custom = {
                output_dir = typst_test_cache_path("provider-profile"),
            },
        },
    },
})
assert(
    typst.ui.status().status == "provider-idle",
    "status() should expose custom provider stopped status"
)
assert(
    events[5] and events[5].name == "TypstCompileStopped",
    "custom stop should emit stopped event"
)
assert(
    events[5].data.status == "idle",
    "custom stop event should expose final status"
)

local idle_stop_result = nil
local idle_stop_handle = typst.compiler.stop({}, function(result)
    idle_stop_result = result
end)
assert(
    idle_stop_handle == nil,
    "idle custom stop should not return a provider handle"
)
assert(
    idle_stop_result and idle_stop_result.stopped,
    "idle custom stop should report stopped"
)
assert(
    idle_stop_result.idle,
    "idle custom stop should be marked as an idle no-op"
)
assert(
    calls[4] == nil,
    "idle custom stop should not call the provider stop method"
)
assert(
    events[6] == nil,
    "idle custom stop should not emit another stopped event"
)

typst.compiler.watch({ profile = "custom" })
assert(
    calls[4].method == "start",
    "custom provider should start another watcher"
)
local replaced = typst.compiler.compile({ profile = "custom" })
assert(
    replaced
        and replaced.restart == true
        and replaced.next_handle
        and replaced.next_handle.code == 0,
    "custom compile should return a restart result tracking the replacement compile"
)
assert(
    calls[5].method == "stop",
    "custom compile should stop the active watcher first"
)
assert(
    calls[6].method == "compile",
    "custom compile should run after stopping the active watcher"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "custom compile should clear the previous watcher"
)
assert(
    typst_test_compiler(project).status == "success",
    "custom compile should finish after replacing the watcher"
)

local failing_provider = {
    name = "failing-provider",
    compile = function(_, callback)
        callback({
            code = 1,
            stdout = "",
            stderr = "boom",
            stale = false,
        })
        return nil
    end,
    start = function()
        return { provider = "failing-watch", pending = true }
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stopped = true, stale = false })
        end
    end,
    status = function()
        return typst_test_compiler(project).status
    end,
    output = function()
        return typst_test_cache_path("provider-output/failing.pdf")
    end,
}

typst.setup({
    root = root,
    compile = {
        provider = failing_provider,
    },
})
local failing_handle = typst.compiler.compile()
assert(
    failing_handle and failing_handle.code == 1,
    "failing provider terminal result should be returned"
)
assert(
    typst_test_compiler(project).status == "error",
    "failing provider should set compiler status to error"
)
assert(
    typst_test_compiler(project).last_result
        and typst_test_compiler(project).last_result.stderr == "boom",
    "failing external provider result should be recorded"
)

typst.setup({
    root = root,
    compile = {
        provider = "typst_test_missing_provider_module",
    },
})
local load_failed = nil
local load_handle = typst.compiler.compile({}, function(result)
    load_failed = result
end)
assert(
    load_handle and load_handle.reason == "provider_load_failed",
    "missing string provider should return a structured failure handle"
)
assert(
    load_failed and load_failed.reason == "provider_load_failed",
    "missing string provider should report a structured compile result"
)
assert(
    typst_test_compiler(project).status == "error",
    "missing string provider should set compiler status to error"
)
assert(
    typst_test_compiler(project).last_result
        and typst_test_compiler(project).last_result.reason
            == "provider_load_failed",
    "missing string provider failure should be recorded"
)

local normalized_provider = {
    name = "normalized-provider",
    compile = function(_, callback)
        callback({ ok = true, stale = false })
        return nil
    end,
    start = function()
        return { provider = "normalized-watch", pending = true }
    end,
    stop = function(_, callback)
        if callback then
            callback({ stopped = true, stale = false })
        end
        return nil
    end,
    status = function()
        return typst_test_compiler(project).status
    end,
    output = function()
        return typst_test_cache_path("provider-output/normalized.pdf")
    end,
}

typst.setup({
    root = root,
    compile = {
        provider = normalized_provider,
    },
})
local normalized_success = nil
typst.compiler.compile({}, function(result)
    normalized_success = result
end)
assert(
    normalized_success
        and normalized_success.ok == true
        and normalized_success.code == 0,
    "ok=true provider results should normalize to code 0"
)
assert(
    typst_test_compiler(project).status == "success",
    "ok=true provider results should set compiler success"
)

normalized_provider.compile = function(_, callback)
    callback({ ok = false, stderr = "normalized boom", stale = false })
    return nil
end
typst.setup({
    root = root,
    compile = {
        provider = normalized_provider,
    },
})
local normalized_failure = nil
typst.compiler.compile({}, function(result)
    normalized_failure = result
end)
assert(
    normalized_failure
        and normalized_failure.ok == false
        and normalized_failure.code == 1,
    "ok=false provider results should normalize to code 1"
)
assert(
    typst_test_compiler(project).status == "error",
    "ok=false provider results should set compiler error"
)

assert(typst.compiler.watch(), "normalized provider watch should start")
local normalized_stop = nil
typst.compiler.stop({}, function(result)
    normalized_stop = result
end)
assert(
    normalized_stop and normalized_stop.stopped and normalized_stop.code == 0,
    "stopped provider results without code should normalize to code 0"
)
assert(
    typst_test_compiler(project).status == "idle",
    "stopped provider results should return compiler to idle"
)

local idle_restart_calls = {}
local idle_restart_provider = {
    name = "idle-restart-provider",
    compile = function(_, callback)
        idle_restart_calls[#idle_restart_calls + 1] = "compile"
        callback({ ok = true, stale = false })
        return nil
    end,
    start = function()
        idle_restart_calls[#idle_restart_calls + 1] = "start"
        return { provider = "idle-restart-watch", pending = true }
    end,
    stop = function(_, callback)
        idle_restart_calls[#idle_restart_calls + 1] = "stop"
        callback({ idle = true, stale = false })
        return nil
    end,
    status = function()
        return typst_test_compiler(project).status
    end,
    output = function()
        return typst_test_cache_path("provider-output/idle-restart.pdf")
    end,
}

typst.setup({
    root = root,
    compile = {
        provider = idle_restart_provider,
    },
})
assert(typst.compiler.watch(), "idle restart provider watch should start")
local idle_restarted = typst.compiler.compile({})
assert(
    idle_restarted
        and idle_restarted.restart == true
        and idle_restarted.next_handle
        and idle_restarted.next_handle.ok == true,
    "idle stop result should allow the replacement compile to start"
)
assert(
    table.concat(idle_restart_calls, ",") == "start,stop,compile",
    "idle restart should stop the watcher then compile"
)
assert(
    typst_test_compiler(project).status == "success",
    "idle restart replacement compile should finish successfully"
)

local ok, err = pcall(function()
    typst.setup({
        compile = {
            provider = {
                compile = function() end,
            },
        },
    })
end)
assert(not ok, "invalid compile provider should fail validation")
assert(tostring(err):match("compile%.provider%.start"), tostring(err))

vim.cmd("qa!")
