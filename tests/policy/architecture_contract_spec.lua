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
for _, text in ipairs({
    "Subtractive Architecture Rule",
    "Not Allowed During Stable-Core Hardening",
    "runtime.resource_manager is the reset/prune/exit cleanup entry point",
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
}) do
    assert(
        vim.fn.filereadable(path) == 0,
        "stable-core hardening should not restore alias file: " .. path
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
    "lua/typst/workflows/render.lua",
    "lua/typst/workflows/render/provider.lua",
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
