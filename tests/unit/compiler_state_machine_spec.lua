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
end, debug.traceback)

if not ok then
    error(err)
end

print("compiler_state_machine_spec: ok")
