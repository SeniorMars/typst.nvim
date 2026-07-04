local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local contract = require("typst.integrations.provider_contract")
local provider_adapter = require("typst.integrations.provider_adapter")
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
local structural_results = contract.structural_results()
local result_contract = contract.result_contract()
assert(
    result_contract.version == 1,
    "provider result contract should be versioned"
)
for _, field in ipairs(result_contract.common_fields or {}) do
    assert(
        docs:find("`" .. field .. "`", 1, true)
            or docs:find(field .. "?", 1, true),
        ("provider docs should document common result field `%s`"):format(field)
    )
end
for _, text in ipairs({
    "TypstResult",
    "TypstPending",
    "ok = false, reason, message",
}) do
    assert(
        docs:find(text, 1, true),
        "provider docs should document canonical result grammar: " .. text
    )
end
assert(
    docs:find("stopped = true", 1, true)
        and docs:find("only after shutdown is confirmed", 1, true),
    "provider docs should document canonical result grammar: stopped = true only after shutdown is confirmed"
)
assert(
    provider_adapter.result_like({ ok = true }) == true,
    "explicit provider result fields should be terminal"
)
assert(
    provider_adapter.result_like({ path = "/tmp/main.pdf" }) == false,
    "path-only provider tables should not be generic terminal results"
)
assert(
    provider_adapter.result_like({ diagnostics = {} }) == false,
    "diagnostics-only provider tables should not be generic terminal results"
)
assert(
    docs:find(
        "Generic table returns are terminal only when they\n  include explicit result fields",
        1,
        true
    )
        and docs:find(
            "as `path`, `output`, `artifacts`, `by_buffer`, or `diagnostics` is not\n  terminal by default",
            1,
            true
        ),
    "provider docs should match stricter generic result classification"
)
assert(
    docs:find(
        "provider adapters must opt into\nthose shapes or normalize them",
        1,
        true
    ),
    "provider docs should repeat structural-shape opt-in guidance"
)
assert(
    not docs:find(
        "`output`, `path`, `artifacts`, `by_buffer`, or `diagnostics` are\n  treated as terminal results",
        1,
        true
    ),
    "provider docs should not document old shape-based terminal detection"
)
for kind, fields in pairs(structural_results) do
    assert(
        docs:find("`" .. kind .. "`", 1, true),
        ("provider docs should list structural result kind `%s`"):format(kind)
    )
    for _, field in ipairs(fields) do
        assert(
            docs:find("`" .. field .. "`", 1, true),
            ("provider docs should list structural field `%s`"):format(field)
        )
    end
end
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
local conformance_cases = contract.conformance_cases()
local conformance_by_id = {}
for _, case in ipairs(conformance_cases) do
    conformance_by_id[case.id] = case
    assert(
        docs:find("`" .. case.id .. "`", 1, true),
        ("provider docs should list conformance fixture `%s`"):format(case.id)
    )
    assert(
        docs:lower():find(case.label:lower(), 1, true),
        ("provider docs should describe conformance fixture `%s`"):format(
            case.label
        )
    )
end
local conformance_matrix = contract.conformance_matrix()
for _, kind in ipairs(contract.kinds()) do
    local cases = conformance_matrix[kind]
    assert(
        cases,
        ("provider kind `%s` should have conformance cases"):format(kind)
    )
    local kind_cases = {}
    for _, case in ipairs(cases) do
        kind_cases[case.id] = true
    end
    for id, case in pairs(conformance_by_id) do
        if case.required then
            assert(
                kind_cases[id],
                ("provider kind `%s` should cover conformance case `%s`"):format(
                    kind,
                    id
                )
            )
        end
    end
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

local structural_provider_paths = {
    ["lua/typst/preview/source_maps.lua"] = "result_fields",
    ["lua/typst/integrations/semantic.lua"] = "result_fields",
    ["lua/typst/lint/init.lua"] = "normalize",
    ["lua/typst/syntax/grammar.lua"] = "normalize",
    ["lua/typst/workflows/artifacts.lua"] = "normalize",
    ["lua/typst/workflows/render/provider.lua"] = "normalize",
    ["lua/typst/viewer/generic.lua"] = "normalize",
    ["lua/typst/viewer/source_sync.lua"] = "normalize",
    ["lua/typst/workflows/development.lua"] = "result_fields",
    ["lua/typst/workflows/eval.lua"] = "result_fields",
    ["lua/typst/workflows/templates.lua"] = "result_fields",
}
for rel, expected in pairs(structural_provider_paths) do
    assert(
        read(rel):find(expected, 1, true),
        rel
            .. " should opt structural provider returns into explicit result fields"
    )
end

local compiler_output_query = read("lua/typst/compiler/provider_binding.lua")
assert(
    compiler_output_query:find(
        "Compiler output provider returned no result",
        1,
        true
    )
        and compiler_output_query:find('type(output) == "string"', 1, true),
    "compiler output provider lookup is a string-only exception, not a structural table result"
)

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
