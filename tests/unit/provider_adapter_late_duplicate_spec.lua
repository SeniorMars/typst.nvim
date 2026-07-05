local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")

local late_callback = nil
local late_results = {}
local pending = adapter.invoke(
    function(_, _, callback)
        late_callback = callback
        return {
            pending = true,
            cancel = function(_, opts)
                return true,
                    {
                        stopped = true,
                        reason = opts and opts.reason,
                    }
            end,
        }
    end,
    nil,
    {},
    {},
    {
        kind = "compiler",
        provider_name = "late-timeout",
        timeout_ms = 10,
        on_result = function(result)
            late_results[#late_results + 1] = result
        end,
    }
)
assert(pending and pending.pending == true, "provider should start pending")
assert(
    vim.wait(1000, function()
        return #late_results == 1
    end, 5),
    "provider timeout should finish once"
)
assert(
    late_results[1].reason == "timeout",
    "first terminal result should be timeout"
)
assert(late_callback)({ ok = true, value = "late-success" })
vim.wait(20)
assert(
    #late_results == 1 and late_results[1].reason == "timeout",
    "late provider callback after timeout should be ignored"
)

local duplicate_results = {}
local duplicate = adapter.invoke(
    function(_, _, callback)
        vim.schedule(function()
            callback({ ok = true, value = 1 })
            callback({ ok = true, value = 2 })
        end)
        return { pending = true }
    end,
    nil,
    {},
    {},
    {
        kind = "format",
        provider_name = "late-duplicate",
        timeout_ms = 1000,
        on_result = function(result)
            duplicate_results[#duplicate_results + 1] = result
        end,
    }
)
assert(
    duplicate and duplicate.pending == true,
    "duplicate provider should be pending"
)
assert(
    vim.wait(1000, function()
        return #duplicate_results > 0
    end, 5),
    "scheduled provider callback should finish"
)
assert(
    #duplicate_results == 1 and duplicate_results[1].value == 1,
    "duplicate provider callbacks should keep the first terminal result"
)

vim.cmd("qa!")
