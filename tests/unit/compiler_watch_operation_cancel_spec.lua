local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst_watcher = require("typst.compiler.typst")
local compiler_service = require("typst.project.services.compiler")
local project_services = require("typst.project.services")

local cancel_called = false
local cancel_opts
local result_callbacks = {}
local settle_callbacks = {}
local handle = {
    is_closing = function()
        return false
    end,
}
local operation = {
    handle = handle,
}
operation.cancel = function(first, second)
    cancel_called = true
    cancel_opts = first == operation and second or first
    return false, { pending = true, stopping = true, stopped = false }
end
operation.on_result = function(self, callback)
    assert(self == operation, "operation result callback should use colon style")
    result_callbacks[#result_callbacks + 1] = callback
    return self
end
operation.on_settle = function(self, callback)
    assert(self == operation, "operation settle callback should use colon style")
    settle_callbacks[#settle_callbacks + 1] = callback
    return self
end
local project = {
    key = "watch-operation-cancel",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    services = project_services.new_state(),
}
local watcher = {
    handle = handle,
    operation = operation,
    deps_path = root .. "/tests/.tmp/watch-deps.json",
    generation = 1,
    stopping = false,
}

compiler_service.set(project, {
    watcher = watcher,
    watcher_operation = operation,
    watch_generation = 1,
    status = "watching",
})

local callback_result
local returned = typst_watcher.stop(project, function(result)
    callback_result = result
end)

assert(returned == handle, "watch stop should return the active handle")
assert(cancel_called, "watch stop should cancel the operation")
assert(
    cancel_opts and cancel_opts.reason == "watcher_stop",
    "watch stop should pass operation cancel reason"
)
assert(watcher.stopping == true, "watcher should enter stopping state")
assert(
    watcher.kill_timer == nil,
    "operation-backed stop should not install a watcher-local kill timer"
)
assert(
    watcher.stop_callbacks == nil,
    "operation-backed stop should not use watcher-local callback queue"
)
assert(
    #settle_callbacks == 1,
    "operation-backed stop should attach one operation settle callback"
)
assert(
    #result_callbacks == 0,
    "operation-backed stop should not attach result callbacks when settle is available"
)

settle_callbacks[1]({ code = 0, stdout = "", stderr = "" }, operation)
assert(callback_result, "operation-backed stop callback should run")
assert(
    callback_result.stopped == true,
    "operation-backed stop callback should receive stopped payload"
)
assert(
    callback_result.watch == true,
    "operation-backed stop callback should be marked as watch result"
)

vim.cmd("qa!")
