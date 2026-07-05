local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local fake_provider = require("tests.helpers.fake_provider")
local project_helper = require("tests.helpers.project")
local typst = require("typst")

local main = root .. "/tests/fixtures/basic/main.typ"

local function setup_project(provider)
    return project_helper.open_typst_project({
        main = main,
        setup = {
            root = root,
            compile = {
                provider = provider,
            },
            project = {
                import_scan = false,
            },
        },
    }).project
end

local terminal_provider = fake_provider.compiler({
    name = "sync-terminal-watch-provider",
    compile = function()
        return { ok = true, code = 0, stale = false }
    end,
    start = function()
        return {
            ok = true,
            code = 0,
            stale = false,
            message = "watch finished synchronously",
        }
    end,
    output = function()
        return typst_test_cache_path("sync-terminal-watch/output.pdf")
    end,
})
local project = setup_project(terminal_provider)
local started_saw_watcher = nil
local group = vim.api.nvim_create_augroup(
    "TypstProviderTerminalWatchSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TypstCompileStarted",
    callback = function()
        started_saw_watcher = typst_test_compiler(project).watcher ~= nil
    end,
})
local terminal_result = nil
local handle = typst.compiler.watch({}, function(result)
    terminal_result = result
end)
vim.api.nvim_del_augroup_by_id(group)

assert(handle and handle.ok == true, "sync terminal start should return result")
assert(
    started_saw_watcher == false,
    "started event should not expose terminal result as active watcher"
)
assert(
    terminal_result and terminal_result.code == 0,
    "sync terminal watch result should reach callback"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "sync terminal watch result should not remain active watcher"
)
assert(
    typst_test_compiler(project).status == "success",
    "sync terminal watch result should apply terminal status"
)

project = setup_project(fake_provider.compiler({
    name = "idle-terminal-watch-provider",
    compile = function()
        return fake_provider.pending()
    end,
    start = function()
        return { idle = true, stopped = true, code = 0, stale = false }
    end,
    output = function()
        return typst_test_cache_path("idle-terminal-watch/output.pdf")
    end,
}))

handle = typst.compiler.watch({}, function(result)
    terminal_result = result
end)
assert(
    handle and handle.idle == true,
    "idle terminal start should return a terminal result"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "idle terminal watch result should not remain active watcher"
)

local pending_compile = {
    pending = true,
    reason = "starting compile",
    cancel = function() end,
}
project = setup_project(fake_provider.compiler({
    name = "pending-compile-provider",
    compile = function()
        return pending_compile
    end,
    start = terminal_provider.start,
    output = function()
        return typst_test_cache_path("pending-compile/output.pdf")
    end,
}))

handle = typst.compiler.compile({}, function() end)
local compiler_state = typst_test_compiler(project)
assert(
    handle and handle.pending == true and handle.reason == "starting compile",
    "pending compile handle metadata should be preserved"
)
assert(
    compiler_state.process
        and compiler_state.process.pending == true
        and compiler_state.process.handle == pending_compile,
    "pending compile handles with reason metadata should be stored as active processes"
)

local pending_watch = {
    pending = true,
    message = "starting watcher",
    cancel = function() end,
}
project = setup_project(fake_provider.compiler({
    name = "pending-watch-provider",
    compile = terminal_provider.compile,
    start = function()
        return pending_watch
    end,
    output = function()
        return typst_test_cache_path("pending-watch/output.pdf")
    end,
}))

handle = typst.compiler.watch({}, function() end)
compiler_state = typst_test_compiler(project)
assert(
    handle and handle.pending == true and handle.message == "starting watcher",
    "pending watch handle metadata should be preserved"
)
assert(
    compiler_state.watcher
        and compiler_state.watcher.pending == true
        and compiler_state.watcher.handle == pending_watch,
    "pending watch handles with message metadata should be stored as active watchers"
)
assert(
    compiler_state.status == "watching",
    "pending watch handles should leave the project in watching state"
)

vim.cmd("qa!")
