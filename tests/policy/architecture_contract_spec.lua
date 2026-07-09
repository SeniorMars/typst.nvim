local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function read(path)
    return table.concat(vim.fn.readfile(path), "\n")
end

-- This is an intentionally brittle policy smoke test. It catches obvious
-- ownership-boundary drift cheaply; it is not a complete Lua static analyzer.
local function assert_not_required(path, modules)
    local text = read(path)
    for _, module in ipairs(modules) do
        assert(
            not text:find('require("' .. module .. '")', 1, true)
                and not text:find("require('" .. module .. "')", 1, true),
            ("%s must not require %s"):format(path, module)
        )
    end
end

local architecture = read("docs/architecture.md")
local provider_adapter = read("lua/typst/integrations/provider_adapter.lua")
local provider_lifecycle = read("lua/typst/integrations/provider_lifecycle.lua")
for _, text in ipairs({
    "Subtractive Architecture Rule",
    "Not Allowed During Stable-Core Hardening",
    "runtime.resource_manager is the reset/prune/exit cleanup entry point",
    "deferred import-scan scheduling",
    "Preview Backend Interface",
    "Do not add a preview backend registry",
    "typst.integrations.provider_lifecycle",
    "adapter wholesale onto `core.operation`",
    "Do not move watch cycles into `core.operation`",
    "expanding this into a render framework",
    "boring default artifact opener",
    "`typst.core.util` is a compatibility convenience",
    "do not churn unrelated",
    "files solely to remove `core.util`",
    "Current Boundary Limits",
    "Do not add speculative controller namespaces",
}) do
    assert(
        architecture:find(text, 1, true),
        "architecture docs should include: " .. text
    )
end
assert(
    not architecture:find("The ideal expanded target is", 1, true),
    "architecture docs should not present the old expanded inventory as a target"
)
assert(
    not architecture:find("Post-Stable Target Boundaries", 1, true),
    "architecture docs should not present post-stable expansion targets"
)
assert(
    provider_adapter:find(
        'require("typst.integrations.provider_lifecycle")',
        1,
        true
    ),
    "provider_adapter should keep provider_lifecycle until it actually migrates onto core.operation"
)
assert(
    provider_lifecycle:find("Temporary provider lifecycle bridge", 1, true),
    "provider_lifecycle should document its temporary bridge role"
)
assert(
    not provider_lifecycle:find('require("typst.core.operation")', 1, true),
    "provider_lifecycle should not become a second operation adapter"
)

for _, path in ipairs({
    "lua/typst/task",
    "lua/typst/tasks",
    "lua/typst/jobs",
    "lua/typst/providers",
    "lua/typst/provider_specs",
    "lua/typst/project/index",
    "lua/typst/runtime/event_bus",
    "lua/typst/ui/elements",
    "lua/typst/ui/layouts",
    "lua/typst/integrations/pickers",
    "lua/typst/preview/backends/registry",
}) do
    assert(
        vim.fn.isdirectory(path) == 0,
        "stable-core hardening should not add framework directory: " .. path
    )
end

for _, path in ipairs({
    "lua/typst/compiler/restart_handle.lua",
    "lua/typst/compiler/typst_watcher.lua",
    "lua/typst/compiler/watch.lua",
    "lua/typst/compiler/watch_parser.lua",
    "lua/typst/config/validation.lua",
    "lua/typst/edit/toc.lua",
    "lua/typst/edit/treesitter.lua",
    "lua/typst/resources/cleanup.lua",
    "lua/typst/resources/drivers/editor_state.lua",
    "lua/typst/resources/supervisor.lua",
    "lua/typst/runtime/hooks.lua",
    "lua/typst/preview/backends/registry.lua",
    "lua/typst/preview/backends/delegated.lua",
    "lua/typst/preview/backends/delegated_runtime.lua",
    "lua/typst/integrations/typst_preview.lua",
    "lua/typst/compiler/result.lua",
    "lua/typst/viewer/init.lua",
}) do
    assert(
        vim.fn.filereadable(path) == 0,
        "stable-core hardening should not restore alias file: " .. path
    )
end

for _, shim in ipairs({
    {
        path = "lua/typst/preview/backends/callback.lua",
        text = "typst.preview.backends.custom",
    },
    {
        path = "lua/typst/preview/backends/viewer_fallback.lua",
        text = "typst.preview.backends.viewer",
    },
    {
        path = "lua/typst/preview/backends/native.lua",
        text = "typst.preview.native",
    },
}) do
    local source = read(shim.path)
    assert(
        source:find(shim.text, 1, true)
            and not source:find("vim.api.nvim_create_autocmd", 1, true)
            and not source:find("vim.system", 1, true),
        "compatibility shim should stay tiny and delegating: " .. shim.path
    )
end

assert_not_required("lua/typst/project/resolver.lua", {
    "typst.compiler",
    "typst.preview",
    "typst.viewer",
    "typst.diagnostics.publisher",
    "typst.resources.outputs",
})
for _, path in
    ipairs(vim.fn.globpath("lua/typst/diagnostics", "**/*.lua", false, true))
do
    local text = read(path)
    if text:find("vim.diagnostic.set", 1, true) then
        assert(
            path:match("lua/typst/diagnostics/publisher%.lua$"),
            "typst diagnostics writes must go through diagnostics.publisher: "
                .. path
        )
    end
end

for _, path in ipairs({
    "lua/typst/compiler/typst_compile.lua",
    "lua/typst/compiler/watch/runner.lua",
    "lua/typst/compiler/generic.lua",
    "lua/typst/workflows/artifacts.lua",
    "lua/typst/workflows/render/provider.lua",
    "lua/typst/workflows/render/preflight.lua",
}) do
    local text = read(path)
    assert(
        text:find("typst.resources.outputs", 1, true),
        path .. " writes generated artifacts and must use resources.outputs"
    )
end

for _, path in
    ipairs(vim.fn.globpath("lua/typst/ui/commands", "*.lua", false, true))
do
    local text = read(path)
    assert(
        not text:find("_service.set(", 1, true)
            and not text:find("services.new_state", 1, true),
        "command modules should present UI and avoid service mutation: " .. path
    )
end

for _, path in ipairs(vim.fn.globpath("lua/typst/api", "*.lua", false, true)) do
    if not path:match("lua/typst/api/spec%.lua$") then
        local text = read(path)
        assert(
            not text:find("typst.internal.", 1, true),
            "public API modules should not require internal modules directly: "
                .. path
        )
    end
end

vim.cmd("qa!")
