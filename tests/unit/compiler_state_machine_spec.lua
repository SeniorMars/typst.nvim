local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

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
