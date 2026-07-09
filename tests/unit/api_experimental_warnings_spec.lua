local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local api_exports = require("typst.api.exports")
local log = require("typst.core.log")
local typst = require("typst")

local function experimental_warning_count(symbol)
    local count = 0
    for _, entry in ipairs(log.entries()) do
        if
            entry.level == "warn"
            and entry.message
                == ("typst.nvim Lua API %s is experimental"):format(symbol)
        then
            count = count + 1
        end
    end
    return count
end

local original_notify = vim.notify
vim.notify = function() end

local wrapper_calls = 0
local wrapped = api_exports.experimental_wrapper("unit.experimental", function()
    wrapper_calls = wrapper_calls + 1
end, vim.notify)
local rewrapped =
    api_exports.experimental_wrapper("unit.experimental", wrapped, vim.notify)
assert(
    rewrapped == wrapped,
    "experimental wrappers should not be applied twice"
)
rewrapped()
assert(wrapper_calls == 1, "idempotent experimental wrapper should call target")

local install_api = {}
api_exports.install(install_api, vim.notify)
local first_completion = install_api.completion.complete
api_exports.install(install_api, vim.notify)
assert(
    install_api.completion.complete == first_completion,
    "installing API namespaces twice should not rebuild/re-wrap methods"
)

typst.reset()
typst.setup({
    root = root,
    api = {
        experimental_warnings = false,
    },
})
log.clear()
pcall(typst.completion.complete)
assert(
    experimental_warning_count("completion.complete") == 0,
    "experimental warnings should be disabled by default"
)

typst.setup({
    root = root,
    api = {
        experimental_warnings = true,
    },
})
log.clear()
pcall(typst.completion.complete)
pcall(typst.completion.complete)
assert(
    experimental_warning_count("completion.complete") == 1,
    "experimental namespace calls should warn once when enabled"
)

log.clear()
pcall(typst.project.get)
assert(
    experimental_warning_count("project.get") == 0,
    "stable symbols should not warn"
)

log.clear()
pcall(typst.report, { open = false })
pcall(typst.report, { open = false })
assert(
    experimental_warning_count("report") == 1,
    "experimental root helpers should warn once when enabled"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    api = {
        experimental_warnings = true,
    },
})
log.clear()
pcall(typst.completion.complete)
assert(
    experimental_warning_count("completion.complete") == 1,
    "reset should clear experimental warning once cache"
)

vim.notify = original_notify
vim.cmd("qa!")
