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
