local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

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
    typst_test_compiler(project).process == nil,
    "raw compile timeout should clear the active process"
)
assert(
    typst_test_compiler(project).output_lease == nil,
    "raw compile timeout should release the output lease"
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
    typst_test_compiler(project).watcher == nil,
    "raw watch timeout should clear the active watcher"
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
typst.setup({
    root = root,
    compile = {
        provider = timeout_provider,
        provider_timeout_ms = 20,
    },
})
local timeout_stop = nil
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
    typst_test_compiler(project).watcher == nil,
    "raw stop timeout should clear the active watcher"
)

vim.cmd("qa!")
