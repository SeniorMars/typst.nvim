local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local spec = require("typst.api.spec")

local function assert_module_method(module_name, method_name, label)
    local ok, module = pcall(require, module_name)
    assert(
        ok and type(module) == "table",
        label .. " module missing: " .. module_name
    )
    assert(
        type(module[method_name]) == "function",
        label .. " method missing: " .. module_name .. "." .. method_name
    )
    return module
end

local function normalized_methods(methods)
    local out = {}
    for key, value in pairs(methods or {}) do
        if type(key) == "number" then
            out[value] = value
        else
            out[key] = value
        end
    end
    return out
end

for _, namespace in ipairs(spec.namespaces or {}) do
    local source = namespace.source or {}
    local factory_api = nil
    if source.type == "factory" then
        local module = assert_module_method(
            source.module,
            source.method or "create",
            namespace.name
        )
        factory_api = module[source.method or "create"]({
            notify = function() end,
        })
        assert(
            type(factory_api) == "table",
            namespace.name .. " factory should return an API table"
        )
    end

    for public_name, entry in pairs(normalized_methods(namespace.methods)) do
        if type(entry) == "string" then
            if factory_api then
                assert(
                    type(factory_api[entry]) == "function",
                    namespace.name
                        .. "."
                        .. public_name
                        .. " should resolve from factory"
                )
            else
                assert_module_method(
                    source.module,
                    entry,
                    namespace.name .. "." .. public_name
                )
            end
        elseif type(entry) == "table" and not entry.custom then
            assert_module_method(
                entry.module or source.module,
                entry.method,
                namespace.name .. "." .. public_name
            )
        end
    end
end

for _, global in ipairs(spec.globals or {}) do
    assert_module_method(global.module, global.method, global.name)
end

vim.cmd("qa!")
