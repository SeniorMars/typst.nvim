local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local api_context = require("typst.api.context")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
})

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = ""

local policy = {
    create = false,
    passive = true,
    operation = "compiler.status",
    notify = false,
}

for _, opts in ipairs({ 0, bufnr }) do
    local ok, result = pcall(api_context.project, opts, policy)
    assert(ok, "api_context.project should accept numeric buffer opts")
    assert(
        type(result) == "table",
        "api_context.project should return a structured result"
    )
end

local endpoint = {
    namespace = "compiler",
    name = "status",
    operation = "compiler.status",
    project = policy,
}

local ok, result = pcall(api_context.resolve_endpoint, endpoint, bufnr)
assert(ok, "api_context.resolve_endpoint should accept numeric buffer opts")
assert(
    type(result) == "table",
    "api_context.resolve_endpoint should return a structured result"
)

typst.reset({ force = true })
vim.cmd("qa!")
