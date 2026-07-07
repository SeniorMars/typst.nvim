local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

cleanup()

local callbacks = 0
local orphan = operation.new("unit-reset-orphan")
orphan.handle = {
    kill = function()
        return false, "synthetic kill failure"
    end,
}
orphan:on_finish(function()
    callbacks = callbacks + 1
end)

assert(
    vim.tbl_count(operation.active()) == 1,
    "test operation should start active"
)

local summary = typst.reset({
    force = true,
    operation_timeout_ms = 0,
    operation_kill_timeout_ms = 0,
})
local global = assert(
    summary and summary.global_operations,
    "runtime reset should include global operation summary"
)
assert(
    global.abandoned >= 1,
    "forced reset should abandon unresolved operation"
)
assert(
    vim.tbl_count(operation.active()) == 0,
    "forced reset should clear global active operations"
)
assert(
    vim.tbl_count(operation.retained()) == 0,
    "forced reset should clear global retained operations"
)

orphan:finish({ code = 0, stdout = "", stderr = "" })
assert(
    callbacks == 0,
    "late finish after forced reset should not run stale callbacks"
)

local idle = operation.new("unit-reset-idle")
local idle_callbacks = 0
idle:on_finish(function()
    idle_callbacks = idle_callbacks + 1
end)

local direct = operation.reset()
assert(direct.cancelled == 1, "idle operation should be cancelled")
assert(idle_callbacks == 1, "idle operation finish callback should run")
assert(
    vim.tbl_count(operation.active()) == 0,
    "operation.reset should clear idle active operation"
)

local retained_callbacks = 0
local retained_cleanup = 0
local retained_cancel_failed = 0
local retained = operation.new("unit-reset-retained", {
    cleanup = function()
        retained_cleanup = retained_cleanup + 1
    end,
    on_cancel_failed = function()
        retained_cancel_failed = retained_cancel_failed + 1
    end,
})
retained.handle = {
    kill = function()
        return false, "synthetic kill failure"
    end,
}
retained:on_finish(function()
    retained_callbacks = retained_callbacks + 1
end)
local retained_reset = operation.reset({
    timeout_ms = 0,
    kill_timeout_ms = 0,
})
assert(
    retained_reset.ok == false,
    "non-forced reset should report unconfirmed global operations"
)
assert(
    retained.reset_quiesced == true,
    "non-forced reset should quiesce stale callbacks"
)
assert(
    type(retained.cleanup) == "function",
    "non-forced reset should preserve retained operation cleanup"
)
assert(
    type(retained.on_cancel_failed) == "function",
    "non-forced reset should preserve retained cancel-failed handler"
)
assert(
    retained_cleanup == 0,
    "retained operation cleanup should not run until process exit"
)
retained:finish({ code = 0, stdout = "", stderr = "" })
assert(
    retained_callbacks == 0,
    "late finish after non-forced reset should not run stale callbacks"
)
assert(
    retained_cleanup == 1,
    "late finish after non-forced reset should run preserved cleanup"
)
assert(
    retained_cancel_failed >= 1,
    "cancel-failed handler should run when operation retention begins"
)

cleanup()

vim.cmd("qa!")
