local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local async_module = "typst.core.async"
local adapter_module = "typst.integrations.provider_adapter"
local saved_async = package.loaded[async_module]
local saved_adapter = package.loaded[adapter_module]

local cancelled = nil

package.loaded[adapter_module] = nil
package.loaded[async_module] = {
    schedule = function(fn)
        fn()
    end,
    close_timer = function(timer)
        pcall(function()
            if timer and not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end)
    end,
    cancel_system = function(handle, opts)
        cancelled = {
            handle = handle,
            opts = opts,
            handle_type = type(handle),
        }
        pcall(function()
            if handle and not handle:is_closing() then
                handle:close()
            end
        end)
        return true, { stopped = true }
    end,
}

local adapter = require(adapter_module)
local raw_handle = vim.uv.new_timer()
---@type any
local result = nil

adapter.invoke(
    function()
        return raw_handle
    end,
    "run",
    nil,
    nil,
    {
        kind = "raw-handle",
        provider_name = "raw-provider",
        args = {},
        timeout_ms = 5,
        on_result = function(value)
            result = value
        end,
    }
)

assert(
    vim.wait(500, function()
        return result ~= nil
    end, 5),
    "raw provider handle should time out"
)
assert(result.reason == "timeout", "raw provider timeout should be reported")
assert(
    cancelled and cancelled.handle == raw_handle,
    "raw userdata provider handles should be passed to cancel_system on timeout"
)
assert(
    cancelled.handle_type == "userdata",
    "regression test should exercise a raw userdata handle"
)

package.loaded[adapter_module] = saved_adapter
package.loaded[async_module] = saved_async

vim.cmd("qa!")
