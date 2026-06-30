local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local jobs = require("typst.jobs")

assert(
    jobs.pending == require("typst.core.pending"),
    "jobs.pending should expose the shared pending helper"
)
assert(
    jobs.operation == require("typst.core.operation"),
    "jobs.operation should expose operation tracking"
)
assert(
    jobs.process == require("typst.core.process"),
    "jobs.process should expose process helpers"
)
assert(
    jobs.provider_adapter == require("typst.integrations.provider_adapter"),
    "jobs.provider_adapter should expose provider invocation"
)

vim.cmd("qa!")
