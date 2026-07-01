local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler_service = require("typst.project.services.compiler")
local operations = require("typst.project.services.operations")
local project_services = require("typst.project.services")
local state_machine = require("typst.compiler.state_machine")
local result_compat = require("typst.compiler.result")

local ok, err = xpcall(function()
    assert(
        result_compat == state_machine,
        "compiler.result should remain a compatibility shim"
    )

    local normalized = state_machine.normalize({ ok = true })
    assert(normalized.code == 0, "ok=true should normalize to code 0")
    assert(normalized.stdout == "", "stdout should normalize to a string")
    assert(normalized.stderr == "", "stderr should normalize to a string")
    local idle_normalized = state_machine.normalize({ idle = true })
    assert(
        idle_normalized.stopped == true and idle_normalized.code == 0,
        "idle stop results should normalize as successful stopped results"
    )
    local contradictory_idle =
        state_machine.normalize({ idle = true, stopped = false, code = 0 })
    assert(
        contradictory_idle.idle == false
            and contradictory_idle.stopped == false
            and contradictory_idle.code == 1,
        "idle=true/stopped=false should normalize as an unconfirmed failure with code 1"
    )
    assert(
        require("typst.core.result").is_unconfirmed_stop(contradictory_idle),
        "normalized contradictory idle/stopped=false should remain classified unconfirmed"
    )

    assert(
        state_machine.is_watch_cycle({ watch = true, code = 0 }, "watcher"),
        "watch=true watcher result should be a nonterminal cycle"
    )
    assert(
        not state_machine.terminal({ watch = true, code = 0 }),
        "watch cycle should not be terminal"
    )
    assert(
        state_machine.terminal({ watch = true, terminal = true, code = 0 }),
        "explicit terminal watch result should be terminal"
    )

    local failure_project = {
        key = "state-machine-failure",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        services = project_services.new_state(),
    }
    compiler_service.set(failure_project, {
        process = { kind = "provider-handle" },
        status = "compiling",
    })
    state_machine.apply_status(failure_project, {
        ok = false,
        code = 1,
        stopped = false,
        reason = "compile_failed",
    }, "process")
    assert(
        (compiler_service.get(failure_project) or {}).status == "error",
        "ordinary stopped=false compile failure should be a normal error"
    )
    assert(
        (compiler_service.get(failure_project) or {}).process == nil,
        "ordinary stopped=false compile failure should clear active process"
    )

    local force_project = {
        key = "force-clear-stopping-compile",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        services = project_services.new_state(),
        compiler_provider = {
            provider = { name = "external-force-clear-test" },
            external = true,
        },
    }
    compiler_service.set(force_project, {
        stopping_compile = { handle = { pid = 9001 } },
        status = "stopping_failed",
    })
    local force_result =
        require("typst.compiler").force_clear(force_project, { notify = false })
    assert(
        force_result.ok and force_result.reason == "force_cleared",
        "force_clear should treat stopping_compile as retained compiler state"
    )
    assert(
        (compiler_service.get(force_project) or {}).stopping_compile == nil,
        "force_clear should clear retained stopping_compile records"
    )
    assert(
        (compiler_service.get(force_project) or {}).status == "idle",
        "force_clear should return stopping_compile-only state to idle"
    )

    local notify_project = {
        key = "force-clear-notify",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        services = project_services.new_state(),
        compiler_provider = {
            provider = { name = "external-force-clear-notify" },
            external = true,
        },
    }
    compiler_service.set(notify_project, {
        process = { kind = "provider-handle" },
        status = "stopping_failed",
    })
    local notified = false
    local notify_result = require("typst.compiler.api").force_clear(
        notify_project,
        { notify = false },
        function()
            notified = true
        end
    )
    assert(
        notify_result.ok and notify_result.discarded == true,
        "force_clear API should discard retained state in notify test"
    )
    assert(
        notified == false,
        "force_clear notify=false should suppress successful discard notifications"
    )

    local empty_project = {
        key = "force-clear-empty",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        services = project_services.new_state(),
        compiler_provider = {
            provider = { name = "external-force-clear-empty" },
            external = true,
        },
    }
    local empty_record = assert(operations.begin(empty_project, "compile"))
    local empty_clear = operations.force_clear_compiler(
        empty_project,
        { notify = false },
        function()
            error("notify=false nothing_to_clear should not notify")
        end
    )
    assert(
        empty_clear.ok and empty_clear.reason == "nothing_to_clear",
        "empty force_clear should remain a successful no-op"
    )
    assert(
        empty_clear.discarded ~= true,
        "nothing_to_clear should not be reported as discarded"
    )
    assert(
        empty_project.services.operations.active_by_id[empty_record.id]
            == empty_record,
        "nothing_to_clear should not clear unrelated operation records"
    )

    for _, case in ipairs({
        { result = nil },
        { result = true },
        { result = { stopped = true } },
        { result = { idle = true } },
        { result = { reason = "idle" } },
        { result = { reason = "not_active" } },
        { result = { reason = "already_stopped" } },
        { result = { reason = "provider_not_started" } },
        { result = { ok = true } },
        { result = { code = 0 } },
    }) do
        assert(
            state_machine.stop_allows_restart(case.result),
            ("stop result should allow restart: %s"):format(
                vim.inspect(case.result)
            )
        )
    end

    for _, case in ipairs({
        { result = false },
        { result = "failed" },
        { result = { ok = false } },
        { result = { stopped = false } },
        { result = { idle = true, ok = false } },
        { result = { reason = "idle", stopped = false } },
        { result = { code = 1 } },
    }) do
        assert(
            not state_machine.stop_allows_restart(case.result),
            ("stop result should block restart: %s"):format(
                vim.inspect(case.result)
            )
        )
    end
end, debug.traceback)

if not ok then
    error(err)
end

print("compiler_state_machine_spec: ok")
