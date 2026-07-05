local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local process = require("typst.core.process")

local original_spawn = process.spawn
local finish_seen = nil
local run_ok, run_err = xpcall(function()
    rawset(process, "spawn", function(_, _, handlers)
        handlers.on_exit({
            code = 1,
            stdout = "",
            stderr = "sync failure",
            reason = "spawn_failed",
        })
        return {
            is_closing = function()
                return true
            end,
            kill = function()
                return true
            end,
            wait = function()
                return {
                    code = 1,
                    stdout = "",
                    stderr = "sync failure",
                }
            end,
        }
    end)
    local op = operation.run("sync-finish", { "fake" }, {}, {
        schedule = false,
        on_finish = function(result)
            finish_seen = result
        end,
    })
    assert(op.state == "finished", "synchronous finish must stay finished")
    assert(op.pending == false, "synchronous finish should clear pending")
    assert(op.code == 1, "synchronous finish should copy result fields")
    assert(
        finish_seen and finish_seen.stderr == "sync failure",
        "synchronous finish should run finish callbacks"
    )
end, debug.traceback)

process.spawn = original_spawn
operation.cancel_all({ wait = false })
if not run_ok then
    error(run_err)
end

vim.cmd("qa!")
