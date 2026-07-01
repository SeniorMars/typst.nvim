local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local callbacks = {}

local provider = {
    name = "project-services-provider",
    compile = function(project, callback, run_config)
        callbacks.compile = callback
        typst_test_compiler(project).last_command = {
            "project-services-provider",
            "compile",
            project.main,
        }
        typst_test_compiler(project).last_cwd = project.root
        typst_test_compiler(project).output = typst_test_cache_path(
            "project-services/"
        ) .. (run_config.compile.profile or "default") .. ".pdf"
        return { kind = "compile", pid = 6101 }
    end,
    start = function(project, callback)
        callbacks.watch = callback
        typst_test_compiler(project).last_command = {
            "project-services-provider",
            "watch",
            project.main,
        }
        typst_test_compiler(project).last_cwd = project.root
        return { kind = "watch", pid = 6102 }
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
        return { kind = "stop", pid = 6103 }
    end,
    status = function(project)
        return typst_test_compiler(project).status
    end,
    output = function(project)
        return typst_test_compiler(project).output
    end,
}

local typst = require("typst")
local project_services = require("typst.project.services")
local telemetry = require("typst.core.telemetry")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("project-services-output"),
    compile = {
        provider = provider,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
telemetry.reset()
local project =
    assert(typst.project.attach(0), "project service fixture attaches")
local telemetry_snapshot = telemetry.snapshot()
assert(
    telemetry_snapshot["project.resolve"],
    "project attach should record resolution telemetry"
)
assert(
    telemetry_snapshot["project.commit_attach"],
    "project attach should record commit telemetry"
)
assert(
    telemetry_snapshot["project.attach"],
    "project attach should record overall attach telemetry"
)
assert(
    telemetry_snapshot["project.attach"].last_fields.main_source,
    "project attach telemetry should include main resolution source"
)
assert(
    telemetry_snapshot["project.attach"].last_fields.root_source,
    "project attach telemetry should include root resolution source"
)
local project_context = require("typst.project.context")
local project_registry = require("typst.project")
assert(
    project_context.resolve({ project = project }) == project,
    "project context should prefer an explicit project"
)
assert(
    project_registry.resolve_opts({ project = project }) == project,
    "project registry should expose the shared option resolver"
)
assert(
    project_context.resolve({ bufnr = 0 }) == project,
    "project context should resolve the current attached buffer"
)
assert(
    project_context.resolve({ bufnr = 0 }, { create = false }) == project,
    "project context should return existing buffer ownership without resolving"
)

assert(type(project.services) == "table", "project should own service state")
assert(
    type(project.services.operations) == "table",
    "project should own operation service state"
)
assert(
    type(project.services.compiler) == "table",
    "project should own compiler service state"
)
assert(
    type(project.services.preview) == "table",
    "project should own preview service state"
)
assert(
    type(project.services.artifacts) == "table",
    "project should own artifact service state"
)

local isolated = { services = project_services.new_state() }
project_services.set_compiler(isolated, { output = "/tmp/compiler.pdf" })
assert(
    project_services.artifacts(isolated).output == nil,
    "compiler service updates should not mutate artifact service output"
)
project_services.set_artifacts(isolated, { output = "/tmp/artifact.pdf" })
assert(
    project_services.compiler(isolated).output == "/tmp/compiler.pdf",
    "artifact service updates should not mutate compiler service output"
)

local compile_result = nil
local compile_handle = typst.compiler.compile({}, function(result)
    compile_result = result
end)

assert(
    compile_handle.kind == "compile",
    "service provider compile handle should be returned"
)
assert(
    project.services.operations.active_by_kind.compile ~= nil,
    "compile should be tracked by the project operation supervisor"
)
local compile_record_id =
    next(project.services.operations.active_by_kind.compile)
assert(
    project.services.operations.active_by_id[compile_record_id].generation == 1,
    "compile operation should receive a generation"
)
assert(
    project.services.compiler.status == "compiling",
    "compiler service should mirror compiling status"
)
assert(
    project.services.compiler.process == compile_handle,
    "compiler service should mirror active process handle"
)

callbacks.compile({ code = 0, stale = false })

assert(compile_result and compile_result.code == 0, "compile should finish")
assert(
    project.services.operations.active_by_kind.compile == nil,
    "finished compile should leave no active operation"
)
assert(
    project.services.operations.last.compile.result.code == 0,
    "finished compile result should be recorded"
)
assert(
    project.services.compiler.status == "success",
    "compiler service should mirror success status"
)
assert(
    project.services.compiler.process == nil,
    "compiler service should clear process handle after finish"
)

local watch_handle = typst.compiler.watch()
assert(watch_handle.kind == "watch", "watch handle should be returned")
assert(
    project.services.operations.active_by_kind.watch ~= nil,
    "watch should be tracked by the project operation supervisor"
)
assert(
    project.services.compiler.status == "watching",
    "compiler service should mirror watching status"
)

typst.compiler.stop()
assert(
    project.services.operations.active_by_kind.watch == nil,
    "stop should clear active watch operation"
)
assert(
    project.services.operations.last.stop.result.stopped == true,
    "stop result should be recorded"
)
assert(
    project.services.compiler.status == "idle",
    "compiler service should mirror idle status after stop"
)

local snapshot = require("typst.project.context").snapshot(project)
assert(
    snapshot.services.operations.last.compile.result.code == 0,
    "project snapshots should include operation service results"
)
assert(
    snapshot.services.compiler.status == "idle",
    "project snapshots should include compiler service state"
)

local operations = require("typst.project.services.operations")
local first_render = operations.begin(project, "render")
local second_render = operations.begin(project, "render")
assert(
    first_render.id ~= second_render.id,
    "same-kind operations should receive distinct identities"
)
assert(
    project.services.operations.active_by_id[first_render.id] == first_render
        and project.services.operations.active_by_id[second_render.id]
            == second_render,
    "same-kind operations should remain concurrently tracked"
)
operations.finish(project, second_render, { ok = true, path = "newer.png" })
operations.finish(project, first_render, { ok = true, path = "older.png" })
assert(
    project.services.operations.last.render.generation
        == second_render.generation,
    "older same-kind completions should not replace newer last results"
)

local waited_cancel = operations.begin(project, "export")
local waited_handle = {
    state = "running",
    cancel = function()
        return false, { pending = true, stopping = true, stopped = false }
    end,
    wait = function(self)
        self.state = "finished"
        self.stopped = true
    end,
}
waited_cancel.handle = waited_handle
local waited_summary = operations.cancel_project(project, {
    skip = {},
    wait_timeout_ms = 1,
})
assert(
    waited_summary.cancelled == 1 and waited_summary.failed == 0,
    "operation cancellation summary should honor a confirmed finish after waiting"
)

local uncancellable_record = operations.begin(project, "export")
uncancellable_record.handle = { pending = true, raw = true }
local uncancellable_summary = operations.cancel_project(project, { skip = {} })
assert(
    uncancellable_summary.uncancellable == 1
        and uncancellable_summary.retained == 1,
    "operation cancellation should retain unsupported live handles"
)
assert(
    project.services.operations.active_by_id[uncancellable_record.id] == nil
        and project.services.operations.retained_by_id[uncancellable_record.id]
            ~= nil,
    "uncancellable handles should leave active records and remain retained"
)
assert(
    project.services.operations.retained_by_id[uncancellable_record.id].result.reason
        == "uncancellable_handle",
    "uncancellable retained operations should expose a recovery reason"
)

local false_handle_record = operations.begin(project, "export")
false_handle_record.handle = false
local false_handle_summary = operations.cancel_project(project, { skip = {} })
assert(
    false_handle_summary.stale == 1 and false_handle_summary.uncancellable == 0,
    "false operation handles should be cleared as stale records"
)
assert(
    project.services.operations.active_by_id[false_handle_record.id] == nil
        and project.services.operations.retained_by_id[false_handle_record.id]
            == nil,
    "false operation handles should not be retained as live work"
)

vim.cmd("qa!")
