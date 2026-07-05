local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local log = require("typst.core.log")
local notify = require("typst.core.notify")
local source_maps = require("typst.preview.source_maps")

log.clear()

local original_notify = vim.notify
rawset(vim, "notify", function() end)
local ok = pcall(function()
    notify.user(function()
        error("notify sink failed")
    end, "guarded notification", vim.log.levels.INFO)
end)
rawset(vim, "notify", original_notify)
assert(ok, "throwing injected notify callback should not abort callers")

local logged_notify_failure = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "notification callback failed" then
        logged_notify_failure = true
        break
    end
end
assert(
    logged_notify_failure,
    "throwing injected notify callback should be logged"
)

---@type any
local invalid_forward = source_maps.forward({}, nil, {})
assert(
    invalid_forward.ok == false and invalid_forward.reason == "invalid_position",
    "source-map forward should reject nil positions without throwing"
)

---@type any
local malformed_forward = source_maps.forward({}, { line = 1 }, {})
assert(
    malformed_forward.ok == false
        and malformed_forward.reason == "invalid_position",
    "source-map forward should reject malformed positions without throwing"
)

local called_position = nil
local typst = require("typst")
typst.reset()
typst.setup({
    preview = {
        source_maps = {
            forward = function(_, position)
                called_position = position
                return { ok = true }
            end,
        },
    },
})
---@type any
local string_position = source_maps.forward({}, {
    line = "12",
    column = "3",
}, {})
assert(
    string_position.ok == true,
    "source-map forward should accept numeric strings"
)
assert(
    called_position
        and called_position.line == 12
        and called_position.column == 3,
    "source-map forward should normalize numeric string coordinates"
)

vim.cmd("qa!")
