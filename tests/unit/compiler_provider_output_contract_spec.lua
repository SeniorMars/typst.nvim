local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local services = require("typst.project.services")
local compiler_service = require("typst.project.services.compiler")
local provider_binding = require("typst.compiler.provider_binding")

local project = {
    key = "compiler-provider-output-contract",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    services = services.new_state(),
    compiler_provider = {
        external = false,
        label = "unit-provider",
    },
}

compiler_service.set(project, {
    output = root .. "/stale.pdf",
    outputless = false,
})
provider_binding.refresh_output({
    name = "outputless-provider",
    outputless = true,
}, project, {})

local compiler = compiler_service.get(project)
assert(
    compiler.output == nil,
    "outputless compiler providers should clear stale output paths"
)
assert(
    compiler.outputless == true,
    "outputless compiler providers should mark compiler state outputless"
)

compiler_service.set(project, {
    output = root .. "/stale-again.pdf",
    outputless = true,
})
provider_binding.refresh_output({
    name = "nil-output-provider",
    output = function()
        return nil
    end,
}, project, {})

compiler = compiler_service.get(project)
assert(
    compiler.output == nil,
    "compiler providers that report no output should not retain stale output paths"
)
assert(
    compiler.outputless == nil,
    "non-outputless compiler providers should clear outputless state"
)

provider_binding.refresh_output({
    name = "path-output-provider",
    output = function()
        return root .. "/fresh.pdf"
    end,
}, project, {})

compiler = compiler_service.get(project)
assert(
    compiler.output == root .. "/fresh.pdf",
    "compiler providers that report an output path should store it"
)

vim.cmd("qa!")
