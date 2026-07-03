local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.core.cache_registry")

local entries = registry._entries_for_tests()
assert(#entries > 0, "cache registry should expose contract entries")

local seen = {}
local required_names = {
    artifacts = true,
    completion = true,
    conceal = true,
    diagnostics = true,
    import_scan = true,
    index = true,
    metadata = true,
    outputs = true,
    package = true,
    project_attachments = true,
    project_lifecycle = true,
    state = true,
    symbol = true,
    treesitter = true,
}

local operations = {
    "reset",
    "clear",
    "forget",
    "detach",
    "forget_window",
}

local function hook_name(entry, operation)
    local value = entry[operation]
    if value == true and operation == "reload" then
        return entry.reset
    end
    if value == true then
        return operation
    end
    return value
end

for _, entry in ipairs(entries) do
    assert(type(entry.name) == "string" and entry.name ~= "", "bad cache name")
    assert(
        not seen[entry.name],
        "duplicate cache registry entry: " .. entry.name
    )
    seen[entry.name] = true

    assert(
        type(entry.module) == "string" and entry.module ~= "",
        "bad cache module for " .. entry.name
    )

    local has_hook = false
    for _, operation in ipairs(operations) do
        has_hook = has_hook or entry[operation] ~= nil
        local method = hook_name(entry, operation)
        if method ~= nil then
            assert(
                type(method) == "string" and method ~= "",
                ("cache entry %s has invalid %s hook"):format(
                    entry.name,
                    operation
                )
            )
        end
        local arg_kind = entry[operation .. "_args"]
        if arg_kind ~= nil then
            assert(
                arg_kind == "bufnr" or arg_kind == "winid",
                ("cache entry %s has invalid %s args"):format(
                    entry.name,
                    operation
                )
            )
        end
    end
    has_hook = has_hook or entry.reload ~= nil
    assert(has_hook, "cache entry has no lifecycle hook: " .. entry.name)

    local ok, module = pcall(require, entry.module)
    assert(
        ok,
        ("cache registry module failed to load: %s"):format(entry.module)
    )
    for _, operation in ipairs(operations) do
        local method = hook_name(entry, operation)
        if method ~= nil then
            assert(
                type(module[method]) == "function",
                ("cache entry %s missing %s.%s"):format(
                    entry.name,
                    entry.module,
                    method
                )
            )
        end
    end
    if entry.reload ~= nil then
        local method = entry.reload == true and entry.reset or entry.reload
        assert(
            type(method) == "string" and type(module[method]) == "function",
            ("cache entry %s missing reload hook"):format(entry.name)
        )
    end
end

for name in pairs(required_names) do
    assert(seen[name], "required cache owner missing from registry: " .. name)
end

vim.cmd("qa!")
