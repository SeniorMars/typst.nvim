local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local outputs = require("typst.resources.outputs")

local function cleanup()
    pcall(function()
        operation.reset({
            scope = "all",
            force = true,
            timeout_ms = 0,
            kill_timeout_ms = 0,
        })
    end)
    pcall(function()
        outputs.reset()
    end)
end

cleanup()

local project_callbacks = 0
local project_owned = operation.new("owner-scope-project", {
    owner = "project",
    project_key = "project-a",
})
project_owned:on_finish(function()
    project_callbacks = project_callbacks + 1
end)

local global_reset = operation.reset({
    force = true,
    timeout_ms = 0,
    kill_timeout_ms = 0,
})
assert(
    global_reset.scope == "global",
    "operation.reset should default to global scope"
)
assert(
    global_reset.active == 0,
    "global reset should not count project-owned operations"
)
assert(
    project_owned.state == "starting" and project_owned.pending == true,
    "global reset should not settle project-owned operations"
)
assert(
    project_owned.reset_quiesced ~= true,
    "global reset should not quiesce project-owned callbacks"
)
project_owned:finish({ code = 0, stdout = "", stderr = "" })
assert(
    project_callbacks == 1,
    "project-owned callbacks should survive global operation reset"
)

local global_callbacks = 0
local global_owned = operation.new("owner-scope-global", {
    owner = "global",
})
global_owned:on_finish(function()
    global_callbacks = global_callbacks + 1
end)
local global_only = operation.reset({
    force = true,
    timeout_ms = 0,
    kill_timeout_ms = 0,
})
assert(
    global_only.cancelled == 1,
    "global reset should cancel global operations"
)
assert(
    global_callbacks == 1,
    "global reset should finish idle global operations"
)

local lease_root = typst_test_cache_path("core-operation-owner-scope")
vim.fn.mkdir(lease_root, "p")
local lease_project = {
    key = "project-a",
    root = lease_root,
    main = lease_root .. "/main.typ",
}
local lease = assert(
    outputs.acquire(
        lease_root .. "/main.pdf",
        outputs.owner("operation-owner-scope", lease_project)
    )
)
local project_a = operation.new("owner-scope-project-a", {
    owner = "project",
    project_key = "project-a",
    cleanup = function()
        outputs.release(lease)
    end,
})
local project_b_callbacks = 0
local project_b = operation.new("owner-scope-project-b", {
    owner = "project",
    project_key = "project-b",
})
project_b:on_finish(function()
    project_b_callbacks = project_b_callbacks + 1
end)

local project_scope = operation.reset({
    scope = "project",
    project_key = "project-a",
    force = true,
    timeout_ms = 0,
    kill_timeout_ms = 0,
})
assert(
    project_scope.active == 1,
    "project reset should count matching project operations"
)
assert(
    project_a.state == "finished",
    "project reset should settle matching project operation"
)
assert(
    #outputs.snapshot(lease_project) == 0,
    "project-scoped operation cleanup should release output leases"
)
assert(
    project_b.state == "starting",
    "project reset should not settle another project's operation"
)
project_b:finish({ code = 0, stdout = "", stderr = "" })
assert(
    project_b_callbacks == 1,
    "non-matching project operation callbacks should remain intact"
)

cleanup()

vim.cmd("qa!")
