local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local compiler_process = require("typst.compiler.typst_process")
local compiler_service = require("typst.project.services.compiler")
local project_services = require("typst.project.services")

local project = {
    key = "compiler-stop-callbacks",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    services = project_services.new_state(),
}
---@type any
local handle = {
    is_closing = function()
        return true
    end,
}
local later_callback_ran = false

log.clear()
compiler_service.set(project, {
    process = handle,
    process_operation = { handle = handle },
    active_compile_deps_path = root .. "/tests/.tmp/compile-deps.json",
    stopping_compile = {
        handle = handle,
        deps_path = root .. "/tests/.tmp/compile-deps.json",
        callbacks = {
            function()
                error("bad stop callback")
            end,
            function(result)
                later_callback_ran = true
                assert(result.stopped == true, "stop payload should be stopped")
            end,
        },
    },
    status = "stopping",
})
local handled = compiler_process.finish_stopped_compile(
    project,
    handle,
    { code = 0, stdout = "", stderr = "" }
)

assert(handled == true, "stopping compile should be handled")
assert(later_callback_ran, "later stop callbacks should still run")
assert(
    (compiler_service.get(project) or {}).status == "idle",
    "compiler state should end idle"
)

local saw_log = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "compile stop callback failed" then
        saw_log = true
        break
    end
end
assert(saw_log, "bad stop callback should be logged")

local operation_callbacks = {}
local operation_handle = {
    is_closing = function()
        return true
    end,
}
local fake_operation = {
    handle = operation_handle,
    on_result = function(self, callback)
        self.result_callbacks = self.result_callbacks or {}
        self.result_callbacks[#self.result_callbacks + 1] = callback
        return self
    end,
    on_settle = function(self, callback)
        self.settle_callbacks = self.settle_callbacks or {}
        self.settle_callbacks[#self.settle_callbacks + 1] = callback
        return self
    end,
}
local operation_callback_ran = false
compiler_service.set(project, {
    process = operation_handle,
    process_operation = fake_operation,
    active_compile_deps_path = root .. "/tests/.tmp/compile-deps-op.json",
    stopping_compile = {
        handle = operation_handle,
        operation = fake_operation,
        deps_path = root .. "/tests/.tmp/compile-deps-op.json",
        callbacks = operation_callbacks,
    },
    status = "stopping",
})
local stopping = (compiler_service.get(project) or {}).stopping_compile
compiler_process.add_stop_callback(stopping, function(result)
    operation_callback_ran = true
    assert(result.stopped == true, "operation-backed stop should be stopped")
    assert(
        result.deps_path == root .. "/tests/.tmp/compile-deps-op.json",
        "operation-backed payload should preserve deps path"
    )
end)
assert(
    #operation_callbacks == 0,
    "operation-backed stop callbacks should not use compiler-local queue"
)
assert(
    #(fake_operation.settle_callbacks or {}) == 1,
    "operation-backed stop callback should attach to operation settlement"
)
assert(
    #(fake_operation.result_callbacks or {}) == 0,
    "operation-backed stop callback should not attach to final result when settle is available"
)
handled = compiler_process.finish_stopped_compile(
    project,
    operation_handle,
    { code = 0, stdout = "", stderr = "" }
)
assert(handled == true, "operation-backed stopping compile should be handled")
assert(
    operation_callback_ran == false,
    "operation callback should wait for operation settle phase"
)
for _, callback in ipairs(fake_operation.settle_callbacks or {}) do
    callback({ code = 0, stdout = "", stderr = "" }, fake_operation)
end
assert(operation_callback_ran, "operation-backed stop callback should run")

local unconfirmed_operation = {
    result_callbacks = {},
    settle_callbacks = {},
    on_result = function(self, callback)
        self.result_callbacks[#self.result_callbacks + 1] = callback
        return self
    end,
    on_settle = function(self, callback)
        self.settle_callbacks[#self.settle_callbacks + 1] = callback
        return self
    end,
}
local unconfirmed_callback_ran = false
compiler_process.add_stop_callback({
    handle = operation_handle,
    operation = unconfirmed_operation,
    deps_path = root .. "/tests/.tmp/compile-deps-timeout.json",
}, function(result)
    unconfirmed_callback_ran = true
    assert(
        result.stopped == false,
        "operation-backed compile stop should preserve stopped=false"
    )
    assert(
        result.reason == "timeout",
        "operation-backed compile stop should preserve failure reason"
    )
    assert(
        result.deps_path == root .. "/tests/.tmp/compile-deps-timeout.json",
        "operation-backed compile stop should still add deps path metadata"
    )
end)
assert(
    #(unconfirmed_operation.settle_callbacks or {}) == 1,
    "unconfirmed operation-backed stop should attach to operation settlement"
)
assert(
    #(unconfirmed_operation.result_callbacks or {}) == 0,
    "unconfirmed operation-backed stop should not wait for final result"
)
for _, callback in ipairs(unconfirmed_operation.settle_callbacks or {}) do
    callback({
        ok = false,
        stopped = false,
        reason = "timeout",
        message = "compile stop timed out",
    }, unconfirmed_operation)
end
assert(
    unconfirmed_callback_ran,
    "operation-backed unconfirmed compile stop callback should run"
)

vim.cmd("qa!")
