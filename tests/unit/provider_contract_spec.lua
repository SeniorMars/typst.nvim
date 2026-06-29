local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local contract = require("typst.integrations.provider_contract")
local providers = require("typst.integrations.providers")

local function read(rel)
    local path = root .. "/" .. rel
    local lines = vim.fn.readfile(path)
    return table.concat(lines, "\n")
end

local aliases = contract.aliases()
for alias, kind in pairs(aliases) do
    assert(
        contract.normalize_kind(alias) == kind,
        ("provider alias %s should normalize to %s"):format(alias, kind)
    )
end

local docs = read("docs/provider-contracts.md")
for _, kind in ipairs(contract.kinds()) do
    assert(
        docs:find("`" .. kind .. "`", 1, true),
        ("provider docs should list stable kind `%s`"):format(kind)
    )
    assert(
        #contract.methods(kind) > 0,
        ("provider kind `%s` should define method contract hints"):format(kind)
    )
end

for _, fixture in ipairs(contract.fixture_matrix()) do
    assert(
        docs:lower():find(fixture:lower(), 1, true),
        ("provider docs should mention fixture: %s"):format(fixture)
    )
end

for _, text in ipairs({
    "Native Preview Contract",
    'preview.native = "viewer"',
    'preview.native = "browser"',
    'preview.native = "auto"',
    'preview.export.mode = "compile"',
    'preview.browser.export.mode = "inherit"',
}) do
    assert(
        docs:find(text, 1, true),
        "provider docs should mention native preview contract: " .. text
    )
end

providers.register("compile", "provider-contract-alias", { compile = true })
assert(
    providers.get("compiler", "provider-contract-alias"),
    "registered alias provider should be available by stable kind"
)
assert(
    providers.unregister("compiler", "provider-contract-alias"),
    "registered alias provider should be removable by stable kind"
)

local expected_adapter_users = {
    "lua/typst/compiler/init.lua",
    "lua/typst/compiler/provider_binding.lua",
    "lua/typst/formatting/init.lua",
    "lua/typst/integrations/semantic.lua",
    "lua/typst/lint/init.lua",
    "lua/typst/navigation/picker_backend_helpers.lua",
    "lua/typst/navigation/toc_collect.lua",
    "lua/typst/project/index_providers.lua",
    "lua/typst/preview/source_maps.lua",
    "lua/typst/syntax/grammar.lua",
    "lua/typst/viewer/generic.lua",
    "lua/typst/viewer/source_sync.lua",
    "lua/typst/workflows/artifacts.lua",
    "lua/typst/workflows/development.lua",
    "lua/typst/workflows/eval.lua",
    "lua/typst/workflows/render/provider.lua",
    "lua/typst/workflows/templates.lua",
}

for _, rel in ipairs(expected_adapter_users) do
    local text = read(rel)
    assert(
        text:find('require("typst.integrations.provider_adapter")', 1, true),
        rel .. " should import the shared provider adapter"
    )
    assert(
        text:find("provider_adapter.invoke", 1, true),
        rel .. " should invoke providers through provider_adapter.invoke"
    )
end

local lookup_only = {
    ["lua/typst/health.lua"] = true,
    ["lua/typst/integrations/semantic_provider.lua"] = true,
    ["lua/typst/navigation/picker_backends.lua"] = true,
    ["lua/typst/viewer/generic_helpers.lua"] = true,
}

local violations = {}
local files = vim.fn.globpath(root .. "/lua/typst", "**/*.lua", false, true)
for _, path in ipairs(files) do
    local rel = path:sub(#root + 2)
    local text = table.concat(vim.fn.readfile(path), "\n")
    if
        text:find("providers.resolve(", 1, true)
        and not lookup_only[rel]
        and not text:find("provider_adapter.invoke", 1, true)
    then
        violations[#violations + 1] = rel
            .. " resolves a provider without adapter invocation"
    end
    if
        text:find("providers.get(", 1, true)
        and not lookup_only[rel]
        and not text:find("provider_adapter.invoke", 1, true)
    then
        violations[#violations + 1] = rel
            .. " looks up a provider without adapter invocation"
    end
end

assert(
    #violations == 0,
    "provider-like workflows should share provider_adapter discipline:\n"
        .. table.concat(violations, "\n")
)

vim.cmd("qa!")
