local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")
local contract = require("typst.integrations.provider_contract")

for _, kind in ipairs(contract.kinds()) do
    local sync = adapter.invoke(
        function()
            return { ok = true, kind = kind, mode = "sync" }
        end,
        nil,
        {},
        {},
        {
            kind = kind,
            provider_name = kind .. "-sync",
        }
    )
    assert(sync.ok == true, kind .. " sync success should normalize")
    assert(sync.kind == kind, kind .. " sync success should preserve fields")

    local callbacks = {}
    local callback = adapter.invoke(
        function(_, _, done)
            done({ ok = true, kind = kind, mode = "callback" })
            return { pending = true }
        end,
        nil,
        {},
        {},
        {
            kind = kind,
            provider_name = kind .. "-callback",
            on_result = function(result)
                callbacks[#callbacks + 1] = result
            end,
        }
    )
    assert(
        callback.ok == true and callback.mode == "callback",
        kind .. " callback success should normalize"
    )
    assert(#callbacks == 1, kind .. " callback should publish once")

    callbacks = {}
    local duplicate = adapter.invoke(
        function(_, _, done)
            done({ ok = true, kind = kind, value = 1 })
            done({ ok = true, kind = kind, value = 2 })
            return { pending = true }
        end,
        nil,
        {},
        {},
        {
            kind = kind,
            provider_name = kind .. "-duplicate",
            on_result = function(result)
                callbacks[#callbacks + 1] = result
            end,
        }
    )
    assert(duplicate.value == 1, kind .. " first duplicate should win")
    assert(#callbacks == 1, kind .. " duplicate callback should publish once")
end

vim.cmd("qa!")
