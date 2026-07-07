local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local api_context = require("typst.api.context")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    completion = {
        package_cache_prewarm = false,
    },
})

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = ""

local notifications = {}
local function notify(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end

local silent = api_context.project({
    bufnr = bufnr,
}, {
    create = false,
    operation = "test.silent",
    notify = false,
}, notify)
assert(silent.ok == false, "silent context fixture should fail resolution")
assert(
    #notifications == 0,
    "policy.notify=false should suppress context-layer notification"
)

local explicit = api_context.project({
    bufnr = bufnr,
    notify = true,
}, {
    create = false,
    operation = "test.explicit",
    notify = false,
}, notify)
assert(explicit.ok == false, "explicit notify fixture should fail resolution")
assert(
    #notifications == 1,
    "opts.notify=true should explicitly opt back into notification"
)

local passive = api_context.project({
    bufnr = bufnr,
}, {
    create = false,
    operation = "test.passive",
    passive = true,
}, notify)
assert(passive.ok == false, "passive context fixture should fail resolution")
assert(
    #notifications == 1,
    "passive policy should suppress default context notification"
)

typst.reset({ force = true })
vim.cmd("qa!")
