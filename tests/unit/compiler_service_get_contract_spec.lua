local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler_service = require("typst.project.services.compiler")
local services = require("typst.project.services")

assert(
    compiler_service.get(nil) == nil,
    "compiler_service.get(nil) should be a safe read"
)
assert(
    not pcall(compiler_service.ensure, nil),
    "compiler_service.ensure(nil) should remain strict"
)

local missing_services_project = {
    key = "compiler-service-missing-services",
    root = root,
    main = root .. "/main.typ",
}
assert(
    compiler_service.get(missing_services_project) == nil,
    "compiler_service.get should not create missing services"
)

local project = {
    key = "compiler-service-contract",
    root = root,
    main = root .. "/main.typ",
    services = services.new_state(),
}
local state = assert(
    compiler_service.get(project),
    "compiler_service.get should return an existing compiler service"
)
assert(state.status == "idle", "compiler service reads should normalize status")

local ensured = compiler_service.ensure(missing_services_project)
assert(
    ensured.status == "idle",
    "compiler_service.ensure should create and normalize missing services"
)
assert(
    compiler_service.get(missing_services_project) == ensured,
    "compiler_service.get should read services created by ensure"
)

vim.cmd("qa!")
