local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.core.cache_registry")

local entries = registry._entries_for_tests()
local by_name = {}
for _, entry in ipairs(entries) do
    assert(
        type(entry.name) == "string" and entry.name ~= "",
        "entry needs name"
    )
    assert(
        type(entry.module) == "string" and entry.module ~= "",
        ("entry %s needs module"):format(entry.name or "?")
    )
    assert(
        entry.clear or entry.reload or entry.forget or entry.detach or entry.forget_window,
        ("entry %s needs at least one lifecycle hook"):format(entry.name)
    )
    assert(not by_name[entry.name], ("duplicate entry %s"):format(entry.name))
    by_name[entry.name] = entry
end

for _, owner in ipairs({
    "project_attachments",
    "completion_context",
    "index",
    "import_scan",
    "treesitter",
    "conceal",
}) do
    assert(by_name[owner], ("cache registry missing owner %s"):format(owner))
end

local function hook_name(entry, operation)
    return entry[operation]
end

for _, entry in ipairs(entries) do
    local ok, module = pcall(require, entry.module)
    assert(ok, ("cache registry module %s should load"):format(entry.module))
    for _, operation in ipairs({
        "clear",
        "reload",
        "forget",
        "detach",
        "forget_window",
    }) do
        local method = hook_name(entry, operation)
        if type(method) == "string" then
            assert(
                type(module[method]) == "function",
                ("cache registry entry %s points %s at missing %s.%s"):format(
                    entry.name,
                    operation,
                    entry.module,
                    method
                )
            )
        end
    end
end

vim.cmd("qa!")
