local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local compile_count = 0
local stop_finish = nil
local provider = {
    name = "restart-cancel-provider",
}

function provider.output()
    return typst_test_cache_path("provider-restart-cancel/main.pdf")
end

function provider.status()
    return "idle"
end

function provider.compile(_, _callback)
    compile_count = compile_count + 1
    return {
        pending = true,
        id = compile_count,
        cancel = function(_, opts)
            return true,
                {
                    ok = false,
                    stopped = true,
                    reason = opts and opts.reason or "cancelled",
                }
        end,
    }
end

function provider.start(_, callback)
    return provider.compile(nil, callback)
end

function provider.stop(_, callback)
    stop_finish = callback
    return {
        pending = true,
        cancel = function(_, opts)
            return true,
                {
                    ok = false,
                    stopped = true,
                    reason = opts and opts.reason or "cancelled",
                }
        end,
    }
end

local ok, err = xpcall(function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("provider-restart-cancel"),
        compile = {
            provider = provider,
            provider_timeout_ms = 0,
            deps = false,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local first = typst.compiler.compile()
    assert(
        first and first.pending == true,
        "first provider compile should start"
    )
    assert(compile_count == 1, "provider should start one compile")
    assert(
        typst_test_compiler(project).process ~= nil,
        "provider compile should be tracked as active"
    )

    local restart = typst.compiler.compile()
    assert(
        restart and restart.restart == true,
        "active provider compile should return a restart handle"
    )
    assert(
        type(stop_finish) == "function",
        "provider restart should register a stop callback"
    )

    restart.cancel({ reason = "manual_cancel" })
    assert(
        restart.pending == false and restart.cancel_requested == true,
        "provider restart cancel should finish the restart handle"
    )
    assert(
        compile_count == 1,
        "provider restart cancellation should not synchronously start replacement"
    )

    stop_finish({ ok = true, stopped = true, code = 0 })
    assert(
        compile_count == 1,
        "provider stop completion after cancellation should not start replacement"
    )
end, debug.traceback)

typst.reset({ force = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
