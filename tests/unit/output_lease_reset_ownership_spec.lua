local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local artifacts = require("typst.workflows.artifacts")
local lock_helper = require("tests.helpers.output_locks")
local outputs = require("typst.resources.outputs")

outputs.reset()
lock_helper.reset_lock_dir()

local base = lock_helper.base_dir("output-lease-reset-ownership")
local output = lock_helper.path(base, "artifact-reset-keeps-lease.pdf")
vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")

local project = {
    key = "output-lease-reset-ownership",
    root = base,
    main = lock_helper.path(base, "main.typ"),
}

local lease = assert(outputs.acquire(output, outputs.owner("unit", project)))
assert(
    #outputs.snapshot(project) == 1,
    "test fixture should start with an active output lease"
)

artifacts.reset()
assert(
    #outputs.snapshot(project) == 1,
    "artifact reset must not release global output leases"
)
assert(
    vim.fn.isdirectory(lease.lock_path) == 1,
    "artifact reset must not remove the file-backed output lock"
)

outputs.reset()
assert(
    #outputs.snapshot(project) == 0,
    "resources.outputs.reset should remain the global lease reset owner"
)
assert(
    vim.fn.isdirectory(lease.lock_path) == 0,
    "resources.outputs.reset should remove the file-backed output lock"
)

vim.cmd("qa!")
