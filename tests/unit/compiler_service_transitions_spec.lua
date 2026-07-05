local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local assertions = require("tests.helpers.assertions")
local compiler_service = require("typst.project.services.compiler")
local project_helper = require("tests.helpers.project")
local state_machine = require("typst.compiler.state_machine")

local function project(name)
    return project_helper.new_state_project(name)
end

local function compiler_state(project_state)
    return assert(
        compiler_service.get(project_state),
        "test project should have compiler service state"
    )
end

local compile_project = project("compile-transition")
local compile_handle = { kind = "compile-handle" }
local compile_operation = { kind = "compile-operation" }
compiler_service.start_compile(compile_project, {
    process = compile_handle,
    process_operation = compile_operation,
    output = "main.pdf",
})
local compile_state = compiler_state(compile_project)
assert(
    compile_state.status == "compiling" and compile_state.generation == 1,
    "compile start should set status and generation"
)
assertions.compiler_active_compile(
    compile_project,
    "compile start should expose an active compiler process"
)
compiler_service.finish_compile(compile_project, { code = 0, stdout = "" })
compile_state = compiler_state(compile_project)
assert(
    compile_state.status == "success"
        and compile_state.process == nil
        and compile_state.process_operation == nil,
    "compile finish should clear active compile handles"
)
assertions.compiler_inactive(
    compile_project,
    "compile finish should leave the compiler inactive"
)

local stale_project = project("stale-transition")
compiler_service.start_compile(stale_project, {
    process = { id = "newer" },
    process_operation = { id = "newer-op" },
})
state_machine.apply_status(stale_project, {
    code = 1,
    stale = true,
    reason = "stale_result",
}, "process")
local stale_state = compiler_state(stale_project)
assert(
    stale_state.process and stale_state.process.id == "newer",
    "stale compile finish must not clear newer active process"
)
assert(
    stale_state.status == "compiling",
    "stale compile finish must not replace current status"
)

local watch_project = project("watch-transition")
local watcher = { kind = "watcher", generation = 1 }
compiler_service.start_watch(watch_project, {
    watcher = watcher,
    watcher_operation = { kind = "watch-operation" },
})
state_machine.apply_status(watch_project, {
    watch = true,
    code = 0,
}, "watcher")
local watch_state = compiler_state(watch_project)
assert(
    watch_state.watcher == watcher and watch_state.status == "watching",
    "watch cycle results should not clear the active watcher"
)
assertions.compiler_active_watch(
    watch_project,
    "watch cycle should keep an active watcher"
)
assert(
    watch_state.watch_cycle_status == "success",
    "watch cycle success should be recorded separately from process finish"
)

compiler_service.finish_stop_confirmed(watch_project, {
    code = 0,
    stopped = true,
})
watch_state = compiler_state(watch_project)
assert(
    watch_state.status == "idle"
        and watch_state.watcher == nil
        and watch_state.watcher_operation == nil,
    "confirmed stop should clear active watch state"
)
assertions.compiler_idle(
    watch_project,
    "confirmed stop should leave compiler inactive"
)

local confirmed_lease_project = project("confirmed-stop-lease-transition")
local confirmed_lease = { path = "main.pdf" }
compiler_service.start_watch(confirmed_lease_project, {
    watcher = { kind = "watcher", generation = 1 },
    watcher_operation = { kind = "watch-operation" },
    output_lease = confirmed_lease,
})
compiler_service.finish_stop_confirmed(confirmed_lease_project, {
    code = 0,
    stopped = true,
})
local confirmed_lease_state = compiler_state(confirmed_lease_project)
assert(
    confirmed_lease_state.output_lease == confirmed_lease,
    "confirmed stop should not clear output leases; callers release output ownership first"
)

local unconfirmed_project = project("unconfirmed-stop-transition")
local lease = { path = "main.pdf" }
compiler_service.start_compile(unconfirmed_project, {
    process = { kind = "provider-handle" },
    output_lease = lease,
})
compiler_service.finish_stop_unconfirmed(unconfirmed_project, {
    code = 1,
    stopped = false,
    reason = "timeout",
})
local unconfirmed_state = compiler_state(unconfirmed_project)
assert(
    unconfirmed_state.status == "stopping_failed",
    "unconfirmed stop should mark compiler state as stopping_failed"
)
assert(
    unconfirmed_state.process ~= nil and unconfirmed_state.output_lease == lease,
    "unconfirmed stop should retain active handles and output lease"
)

compiler_service.force_clear(unconfirmed_project, {
    ok = true,
    reason = "force_cleared",
})
local cleared_state = compiler_state(unconfirmed_project)
assert(
    cleared_state.status == "idle"
        and cleared_state.process == nil
        and cleared_state.output_lease == nil,
    "force clear should discard retained compiler handles and leases"
)

vim.cmd("qa!")
