local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local log = require("typst.core.log")

typst.reset()
log.clear()

local module_name = "typst.completion.packages"
local original = package.loaded[module_name]
package.loaded[module_name] = {
    prewarm = function()
        error("prewarm exploded")
    end,
}

local ok, err = pcall(function()
    typst.setup({
        completion = {
            package_cache_prewarm = true,
        },
    })
end)

package.loaded[module_name] = original

assert(ok, tostring(err))

local saw_warning = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "package cache prewarm failed" then
        saw_warning = true
        break
    end
end

assert(
    saw_warning,
    "throwing package prewarm should be logged instead of aborting setup"
)

vim.cmd("qa!")
