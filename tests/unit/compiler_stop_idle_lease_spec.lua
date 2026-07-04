local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler = require("typst.compiler")
local compiler_service = require("typst.project.services.compiler")
local output_ownership = require("typst.resources.outputs")
local path_leases = require("typst.core.path_leases")
local project_services = require("typst.project.services")

local output = typst_test_cache_path("compiler-stop-idle-lease", "main.pdf")
vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")

local project = {
    key = "compiler-stop-idle-lease",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    services = project_services.new_state(),
}

local lease = assert(output_ownership.acquire(output, {
    kind = "compiler-provider-compile",
    project_key = project.key,
    main = project.main,
}))
compiler_service.set(project, {
    status = "idle",
    output = output,
    output_lease = lease,
})

local callback_result = nil
local stop_handle = compiler.stop(project, function(result)
    callback_result = result
end)

assert(stop_handle == nil, "idle stop should not return a provider handle")
assert(
    callback_result and callback_result.stopped == true,
    "idle stop should confirm stopped"
)
assert(
    compiler_service.get(project).output_lease == nil,
    "idle stop should clear retained output lease state"
)
assert(
    not path_leases.active(output),
    "idle stop should release the retained output lease"
)

vim.cmd("qa!")
