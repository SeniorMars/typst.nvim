local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local providers = require("typst.integrations.providers")
local semantic = require("typst.integrations.semantic")
local semantic_provider = require("typst.integrations.semantic_provider")
local typst = require("typst")

local provider_calls = {}
providers.register("semantic", "unit-semantic", {
    name = "unit-semantic",
    mode = "test",
    backend = "registry",
    available_for_project = function(project)
        provider_calls.available = project.main
        return project.main:find("main%.typ$") ~= nil
    end,
    workspace_symbols = function(project, opts)
        provider_calls.workspace_symbols = {
            main = project.main,
            query = opts.query,
        }
        return {
            ok = true,
            provider = "unit-semantic",
            symbols = {
                {
                    name = "custom-symbol",
                    file = project.main,
                    lnum = 1,
                    col = 1,
                },
            },
            count = 1,
        }
    end,
})
providers.register("semantic", "unit-semantic-diagnostics", {
    name = "unit-semantic-diagnostics",
    mode = "test",
    backend = "registry",
    owns_diagnostics = true,
    available_for_project = function(project)
        return project.main:find("main%.typ$") ~= nil
    end,
})
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("semantic-provider-output"),
    diagnostics = {
        source = "fallback",
    },
    integrations = {
        semantic = {
            provider = "unit-semantic",
        },
        tinymist = {
            lsp = "off",
        },
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
local project = assert(typst.project.get(0), "project should attach")

assert(
    semantic_provider.name() == "unit-semantic",
    "semantic provider status should use configured registry provider"
)
assert(
    semantic_provider.available_for_project(project) == true,
    "configured registry provider should report project availability"
)

local snapshot = typst.ui.status()
assert(
    snapshot.semantic_provider == "unit-semantic"
        and snapshot.semantic_provider_mode == "test"
        and snapshot.semantic_provider_backend == "registry"
        and snapshot.semantic_provider_enabled == true
        and snapshot.semantic_provider_attached == true,
    "status() should expose configured semantic provider details"
)
assert(
    snapshot.tinymist_lsp_enabled == false
        and snapshot.tinymist_lsp_attached == false,
    "custom semantic provider should not make Tinymist compatibility fields look attached"
)
assert(
    diagnostics.should_publish(project) == true
        and diagnostics.policy_state(project) == "fallback_active"
        and semantic_provider.owns_diagnostics(project) == false,
    "custom semantic providers should not suppress fallback diagnostics by default"
)
local previous_coc_service_initialized = vim.g.coc_service_initialized
vim.g.coc_service_initialized = true
assert(
    semantic_provider.coc_active() == false,
    "custom semantic providers should not inherit Tinymist/Coc active detection"
)
vim.g.coc_service_initialized = previous_coc_service_initialized

local result = semantic.workspace_symbols(project, {
    query = "custom",
    open = false,
})
assert(
    result
        and result.ok
        and result.provider == "unit-semantic"
        and result.symbols[1].name == "custom-symbol",
    "semantic actions should use the configured registry provider by default"
)
assert(
    provider_calls.workspace_symbols
        and provider_calls.workspace_symbols.query == "custom",
    "semantic provider should receive provider-safe project context and opts"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("semantic-provider-diagnostics-output"),
    diagnostics = {
        source = "fallback",
    },
    integrations = {
        semantic = {
            provider = "unit-semantic-diagnostics",
        },
        tinymist = {
            lsp = "off",
        },
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
project = assert(typst.project.get(0), "project should reattach")

assert(
    semantic_provider.owns_diagnostics(project) == true
        and diagnostics.should_publish(project) == false
        and diagnostics.policy_state(project)
            == "fallback_suppressed_by_semantic_provider",
    "custom semantic provider should suppress fallback diagnostics only when it opts in"
)

providers.unregister("semantic", "unit-semantic")
providers.unregister("semantic", "unit-semantic-diagnostics")
typst.reset()
vim.cmd("qa!")
