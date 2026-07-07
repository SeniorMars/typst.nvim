local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local resources = require("typst.resources.session")
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

typst.setup({
    root = root,
    completion = {
        package_cache_prewarm = false,
    },
})

local late_callbacks = 0
local orphan = operation.new("integration-global-operation")
orphan.handle = {
    kill = function()
        return false, "synthetic kill failure"
    end,
}
orphan:on_finish(function()
    late_callbacks = late_callbacks + 1
end)
local project_owned = operation.new("integration-project-operation", {
    owner = "project",
    project_key = "synthetic-project",
})

local before = resources.global_snapshot()
assert(
    before.operations.active == 1,
    "global operation should be visible in the resource session"
)
assert(
    before.blocker_count >= 1,
    "global active operation should be represented as a blocker"
)
project_owned:finish({ code = 0, stdout = "", stderr = "" })

local nonforced = typst.reset({
    operation_timeout_ms = 0,
    operation_kill_timeout_ms = 0,
})
assert(
    nonforced and nonforced.ok == false,
    "unconfirmed global operations should make reset fail without force"
)
local saw_global_failure = false
for _, failure in ipairs(nonforced.failed or {}) do
    if failure.reason == "global_operations_remain" then
        saw_global_failure = true
    end
end
assert(
    saw_global_failure,
    "reset summary should identify retained global operations"
)

local reset = typst.reset({
    force = true,
    operation_timeout_ms = 0,
    operation_kill_timeout_ms = 0,
})
local global = assert(
    reset and reset.global_operations,
    "runtime reset should report global operation cleanup"
)
assert(
    global.abandoned >= 1,
    "forced reset should abandon unconfirmed global operations"
)

local after = resources.global_snapshot()
assert(
    after.operations.active == 0,
    "global active operations should be cleared after forced reset"
)
assert(
    after.operations.retained == 0,
    "global retained operations should be cleared after forced reset"
)

orphan:finish({ code = 0, stdout = "", stderr = "" })
assert(
    late_callbacks == 0,
    "late global operation callback after reset must not run"
)

cleanup()

vim.cmd("qa!")
