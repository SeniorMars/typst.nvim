local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local output_ownership = require("typst.resources.outputs")
local project_helper = require("tests.helpers.project")
local project_store = require("typst.project.store")
local compiler_service = require("typst.project.services.compiler")
local operations = require("typst.project.services.operations")
local resource_supervisor = require("typst.resources.supervisor")

local function open_project(name)
    return project_helper.open_typst_project({
        name = name,
        files = {
            ["main.typ"] = "= " .. name,
        },
        setup = {
            output_dir = typst_test_cache_path(name .. "-output"),
        },
    })
end

local function detach_for_prune(opened)
    opened.project.bufs[opened.bufnr] = nil
    project_store.clear_buffer(opened.bufnr)
end

local active_compile = open_project("resource-supervisor-active-compiler")
compiler_service.set(active_compile.project, {
    process = { pid = 9001 },
    status = "compiling",
})
detach_for_prune(active_compile)
assert(
    resource_supervisor.has_active_resources(active_compile.project),
    "active compiler process should block project pruning"
)
assert(
    project_store.prune(active_compile.project, "active compiler retention")
        == false,
    "project store should not prune active compiler resources"
)
assert(
    project_store.all()[active_compile.project.key] == active_compile.project,
    "active compiler project should remain registered"
)
compiler_service.set(active_compile.project, {
    clear = { "process" },
    status = "idle",
})
assert(
    project_store.prune(active_compile.project, "compiler released") == true,
    "released compiler resources should allow pruning"
)

local retained_operation =
    open_project("resource-supervisor-retained-operation")
local retained_record =
    assert(operations.begin(retained_operation.project, "export"))
operations.retain(retained_operation.project, retained_record, {
    orphaned = true,
    retained = true,
    stopped = false,
})
detach_for_prune(retained_operation)
assert(
    resource_supervisor.has_active_resources(retained_operation.project),
    "retained operations should block project pruning"
)
assert(
    project_store.prune(retained_operation.project, "retained operation")
        == false,
    "project store should not prune retained operations"
)
operations.finish(retained_operation.project, retained_record, {
    ok = false,
    exited_after_orphan = true,
})
assert(
    project_store.all()[retained_operation.project.key] == nil,
    "finished retained operations should allow detached project pruning"
)

local output_lease = open_project("resource-supervisor-output-lease")
local lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("resource-supervisor-output-lease/main.pdf"),
        output_ownership.owner("resource-supervisor-test", output_lease.project)
    )
)
detach_for_prune(output_lease)
assert(
    resource_supervisor.has_active_resources(output_lease.project),
    "active output leases should block project pruning"
)
assert(
    project_store.prune(output_lease.project, "active output lease") == false,
    "project store should not prune active output leases"
)
assert(output_ownership.release(lease), "test output lease should release")
assert(
    project_store.prune(output_lease.project, "output lease released") == true,
    "released output leases should allow project pruning"
)

local reset_retained = open_project("resource-supervisor-reset-retained")
local reset_record = assert(operations.begin(reset_retained.project, "export"))
local cancel_calls = 0
local fake_operation = {
    state = "orphaned-running",
    wait = function(self)
        self.state = "orphaned-retained"
        self.orphaned = true
        self.retained = true
        self.result = {
            orphaned = true,
            retained = true,
            stopped = false,
        }
        return self
    end,
}
reset_record.handle = {
    operation = fake_operation,
    cancel = function()
        cancel_calls = cancel_calls + 1
        return false, { orphaned = true, reason = "still_running" }
    end,
}
local reset_summary = reset_retained.typst.reset({
    operation_timeout_ms = 0,
    operation_kill_timeout_ms = 0,
    operation_wait_timeout_ms = 0,
    keep_telemetry = true,
})
assert(
    reset_summary and reset_summary.ok == false,
    "non-force reset should report retained operation blockers"
)
assert(cancel_calls == 1, "reset should attempt active operation cancellation")
assert(
    project_store.all()[reset_retained.project.key] == reset_retained.project,
    "non-force reset should retain projects with retained operations"
)
assert(
    reset_retained.project.services.operations.retained_by_id[reset_record.id]
        == reset_record,
    "retained reset operation should remain visible after reset"
)
operations.finish(reset_retained.project, reset_record, {
    ok = false,
    exited_after_orphan = true,
})
reset_retained.project.bufs = {}
project_store.prune(reset_retained.project, "retained reset cleanup")

reset_retained.typst.reset({ force = true })
vim.cmd("qa!")
