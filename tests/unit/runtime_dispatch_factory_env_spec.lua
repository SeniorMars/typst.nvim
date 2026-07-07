local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local dispatch = require("typst.api.runtime_dispatch")

local received_notify = nil
package.loaded["typst.tests.runtime_dispatch_factory"] = {
    create = function(env)
        received_notify = env and env.notify
        return {
            run = function(opts)
                return {
                    ok = true,
                    opts = opts,
                    notify = received_notify,
                }
            end,
        }
    end,
}

local api = {}
local notify = function() end
dispatch.install(api, {
    {
        namespace = "test",
        name = "factory",
        operation = "test.factory",
        project = false,
        handler = {
            module = "typst.tests.runtime_dispatch_factory",
            factory = "create",
            method = "run",
            call = "opts",
        },
        result = {
            resolution_error = "payload",
            protect_handler = true,
            handler_exception = "payload",
        },
    },
}, {
    notify = notify,
})

local result = api.test.factory({ answer = 42 })
assert(result and result.ok == true, "factory endpoint should run")
assert(
    result.notify == notify,
    "runtime dispatch factory should receive install env notify"
)
assert(
    result.opts and result.opts.answer == 42,
    "factory endpoint should receive prepared opts"
)

package.loaded["typst.tests.runtime_dispatch_factory"] = nil

local missing_custom_api = {}
dispatch.install(missing_custom_api, {
    {
        namespace = "test",
        name = "missing_custom",
        operation = "test.missing_custom",
        project = false,
        handler = {
            custom = "does.not.exist",
        },
        result = {
            resolution_error = "payload",
            protect_handler = true,
            handler_exception = "payload",
        },
    },
}, {
    notify = notify,
})

local missing_custom = missing_custom_api.test.missing_custom({})
assert(
    missing_custom and missing_custom.ok == false,
    "missing custom handler should return structured failure"
)
assert(
    missing_custom.reason == "handler_missing",
    "missing custom handler should report handler_missing"
)

vim.cmd("qa!")
