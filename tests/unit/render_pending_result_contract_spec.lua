local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local pending = require("typst.core.pending")
local process = require("typst.core.process")

local original_spawn = process.spawn

local ok, err = xpcall(function()
    rawset(process, "spawn", function(_, _, handlers)
        handlers.on_exit({
            code = 0,
            stdout = "",
            stderr = "",
            path = "render.svg",
        })
        return {
            is_closing = function()
                return true
            end,
            kill = function()
                return true
            end,
            wait = function()
                return { code = 0, stdout = "", stderr = "" }
            end,
        }
    end)

    local result = {
        ok = true,
        pending = true,
        kind = "render",
    }
    local op = operation.attach(result, "render", { "fake-render" }, {}, {
        schedule = false,
    })
    assert(result.operation == op, "attached result should expose operation")
    assert(type(result.cancel) == "function", "attached result should cancel")
    assert(
        type(result.on_finish) == "function",
        "attached result should expose on_finish"
    )

    local callback_result = nil
    local callback_operation = nil
    result:on_finish(function(done, finished)
        callback_result = done
        callback_operation = finished
    end)
    assert(
        callback_result == result,
        "late render result on_finish should receive the result table"
    )
    assert(
        callback_operation == op,
        "late render result on_finish should receive the operation"
    )

    local dot_result = nil
    result.on_finish(function(done)
        dot_result = done
    end)
    assert(
        dot_result == result,
        "dot-style render result on_finish should also receive the result"
    )

    local subscribed = nil
    local subscribed_ok = pending.subscribe(result, function(done)
        subscribed = done
    end)
    assert(subscribed_ok == true, "pending.subscribe should accept result")
    assert(subscribed == result, "pending.subscribe should receive result")
end, debug.traceback)

process.spawn = original_spawn
operation.cancel_all({ wait = false })

if not ok then
    error(err)
end

vim.cmd("qa!")
