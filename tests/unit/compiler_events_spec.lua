local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({ root = root })

local compiler_events = require("typst.compiler.events")
local compiler_service = require("typst.project.services.compiler")
local project_services = require("typst.project.services")

local contract = typst.contract()
local compile_event_payload_keys = {
    "event_kind",
    "compiler_event",
    "status",
    "watch",
    "cycle",
    "generation",
    "watch_generation",
    "cycle_generation",
    "watch_status",
    "last_cycle_status",
    "output_wait_ms",
    "output_wait_attempts",
    "code",
    "deps_path",
}
for _, event_name in ipairs({
    "TypstEventCompileStarted",
    "TypstEventCompiling",
    "TypstEventCompileSuccess",
    "TypstEventCompileFailed",
    "TypstEventCompileStopped",
}) do
    for _, key in ipairs(compile_event_payload_keys) do
        assert(
            vim.tbl_contains(contract.event_payloads[event_name], key),
            ("%s contract should document %s"):format(event_name, key)
        )
    end
end

local pattern, payload = compiler_events.payload("cycle_success", {
    cycle = 4,
    cycle_generation = 9,
    output_wait_ms = 250,
    output_wait_attempts = 3,
    stdout = "must not leak",
})

assert(
    pattern == "TypstCompileSuccess",
    "cycle success should use success event"
)
assert(payload.event_kind == "cycle_success", "cycle kind should be normalized")
assert(
    payload.compiler_event == "success",
    "compiler event should be normalized"
)
assert(payload.watch == true, "cycle payload should identify watch cycles")
assert(payload.status == "success", "cycle payload should report success")
assert(payload.cycle == 4, "cycle payload should retain cycle id")
assert(
    payload.cycle_generation == 9,
    "cycle payload should retain cycle generation"
)
assert(payload.stdout == nil, "raw stdout should not leak into User payloads")

local project = {
    key = "compiler-events-test",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    services = project_services.new_state(),
}
compiler_service.set(project, {
    status = "watching",
    output = typst_test_cache_path("compiler-events/main.pdf"),
})

local seen = {}
vim.api.nvim_create_autocmd("User", {
    pattern = {
        "TypstCompileSuccess",
        "TypstCompileFailed",
        "TypstCompileStopped",
    },
    callback = function(args)
        seen[#seen + 1] = args.data
    end,
})

compiler_events.from_result(project, {
    code = 0,
    watch = true,
    cycle = 5,
    generation = 7,
    watch_generation = 7,
    cycle_generation = 10,
    deps_path = "deps-success.json",
    status = "watching",
    stdout = "ignored",
})

local success = seen[#seen]
assert(success, "compiler event helper should emit the compatibility event")
assert(
    success.event_kind == "cycle_success",
    "emitted event should be normalized"
)
assert(success.key == project.key, "emitted event should include project data")
assert(
    success.output:match("compiler%-events/main%.pdf$"),
    "output should be set"
)
assert(
    success.status == "success",
    "watch cycle success status should be normalized"
)
assert(
    success.watch_status == "watching",
    "watch cycle should retain watcher status separately"
)
assert(success.generation == 7, "generation should be retained")
assert(success.watch_generation == 7, "watch generation should be retained")
assert(success.cycle_generation == 10, "cycle generation should be retained")
assert(success.code == 0, "watch success code should be retained")
assert(success.deps_path == "deps-success.json", "deps path should be retained")
assert(success.stdout == nil, "emitted event should filter raw stdout")

compiler_events.from_result(project, {
    code = 1,
    watch = true,
    cycle = 6,
    generation = 8,
    watch_generation = 8,
    cycle_generation = 11,
    reason = "synthetic",
})

local failure = seen[#seen]
assert(
    failure.event_kind == "cycle_failure",
    "watch failure should be normalized"
)
assert(failure.status == "error", "watch cycle failure status should be error")
assert(
    failure.watch_status == "watching",
    "watch cycle failure should keep watcher status separate"
)
assert(failure.reason == "synthetic", "failure reason should be retained")

compiler_events.from_result(project, { code = 0, idle = true })

local stopped = seen[#seen]
assert(stopped.event_kind == "compile_stopped", "idle result should be stopped")
assert(stopped.idle == true, "idle flag should be retained")

local ok_unknown = pcall(function()
    compiler_events.payload("typo_kind", {})
end)
assert(not ok_unknown, "unknown compiler event kinds should fail fast")

typst.reset({ force = true })
