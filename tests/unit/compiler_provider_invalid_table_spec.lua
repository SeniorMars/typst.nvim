local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local saved_config = package.loaded["typst.config"]
local saved_binding = package.loaded["typst.compiler.provider_binding"]

package.loaded["typst.compiler.provider_binding"] = nil
package.loaded["typst.config"] = {
    unsafe_get = function()
        return {
            compile = {
                provider = {
                    name = "invalid-inline",
                    compile = function() end,
                },
            },
        }
    end,
    provider_label = function()
        return "invalid-inline"
    end,
}

local provider_binding = require("typst.compiler.provider_binding")

local ok, err = xpcall(function()
    ---@type any
    local provider, builtin, external = provider_binding.configured()
    assert(
        builtin == false,
        "invalid inline table should not be treated as built-in"
    )
    assert(
        external == true,
        "invalid inline table should keep external provenance"
    )
    assert(
        type(provider) == "table" and type(provider.load_error) == "table",
        "invalid inline compiler providers should become structured failure providers"
    )
    assert(
        provider.load_error.reason == "provider_invalid",
        "invalid inline compiler provider should report provider_invalid"
    )
    assert(
        provider.load_error.provider == "invalid-inline",
        "invalid inline compiler provider should preserve provider.name"
    )

    local callback_result = nil
    local result = provider.compile({}, function(value)
        callback_result = value
    end)
    assert(
        result.ok == false and result.reason == "provider_invalid",
        "invalid inline compiler provider compile should return structured failure"
    )
    assert(
        callback_result and callback_result.reason == "provider_invalid",
        "invalid inline compiler provider should also notify callback"
    )
end, debug.traceback)

package.loaded["typst.config"] = saved_config
package.loaded["typst.compiler.provider_binding"] = saved_binding

if not ok then
    error(err)
end

do
    local typst = require("typst")
    for _, missing in ipairs({
        "compile",
        "start",
        "stop",
        "status",
        "output",
    }) do
        local provider = {
            name = "invalid-inline",
            compile = function() end,
            start = function() end,
            stop = function() end,
            status = function() end,
            output = function() end,
        }
        provider[missing] = nil
        local setup_ok, setup_err = pcall(function()
            typst.reset()
            typst.setup({
                root = root,
                output_dir = typst_test_cache_path(
                    "invalid-table-provider-output"
                ),
                compile = {
                    provider = provider,
                },
            })
        end)
        assert(
            not setup_ok
                and tostring(setup_err):find(
                    "compile%.provider%." .. missing,
                    1,
                    false
                ),
            ("normal setup should reject inline providers missing %s early"):format(
                missing
            )
        )
    end
end

vim.cmd("qa!")
