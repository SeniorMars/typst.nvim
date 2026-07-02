local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")
local log = require("typst.core.log")

log.clear()

local callback_called = false
local function cancelable(fields)
    fields.cancel = function()
        return true,
            {
                ok = false,
                reason = "cancelled",
                stopped = true,
            }
    end
    return fields
end

local function invoke_returning(value, result_fields)
    return adapter.invoke(
        function(_callback)
            return value
        end,
        "run",
        nil,
        nil,
        {
            kind = "ambiguous-test",
            provider_name = "ambiguous-provider",
            args = {},
            callback_position = 1,
            result_fields = result_fields,
            on_result = function()
                callback_called = true
            end,
        }
    )
end

local handle = invoke_returning(cancelable({
    path = "/tmp/output.pdf",
}))

assert(
    type(handle) == "table" and handle.path == "/tmp/output.pdf",
    "cancelable path tables should remain provider handles"
)

local output_handle = invoke_returning(cancelable({
    output = "/tmp/output.pdf",
}))
assert(
    type(output_handle) == "table" and output_handle.output == "/tmp/output.pdf",
    "cancelable output tables should remain provider handles"
)

local diagnostics_handle = invoke_returning(cancelable({
    diagnostics = {},
}))
assert(
    type(diagnostics_handle) == "table"
        and diagnostics_handle.diagnostics ~= nil,
    "cancelable diagnostics tables should remain provider handles"
)

local by_buffer_handle = invoke_returning(cancelable({
    by_buffer = {},
}))
assert(
    type(by_buffer_handle) == "table" and by_buffer_handle.by_buffer ~= nil,
    "cancelable by_buffer tables should remain provider handles"
)

local source_map_handle = invoke_returning(
    cancelable({
        path = "/tmp/source.typ",
        line = 1,
        column = 1,
    }),
    { path = true, line = true, column = true }
)
assert(
    type(source_map_handle) == "table"
        and source_map_handle.path == "/tmp/source.typ",
    "cancelable provider-specific structural tables should remain handles"
)

assert(
    callback_called == false,
    "ambiguous cancelable handles should not be completed as results"
)

local saw_warning = false
for _, entry in ipairs(log.entries()) do
    if
        entry.level == "warn"
        and entry.message == "provider returned ambiguous handle/result table"
        and entry.fields.provider == "ambiguous-provider"
    then
        saw_warning = true
        break
    end
end
assert(saw_warning, "ambiguous provider handles should produce a warning")

callback_called = false
local explicit_result = invoke_returning({
    path = "/tmp/output.pdf",
    ok = true,
})
assert(
    explicit_result.ok == true and explicit_result.path == "/tmp/output.pdf",
    "explicit ok=true structural tables should still be terminal results"
)
assert(
    callback_called == true,
    "explicit terminal results should still complete through the result path"
)

log.clear()
callback_called = false
local explicit_cancelable_result = invoke_returning({
    path = "/tmp/output.pdf",
    ok = true,
    cancel = function()
        return true
    end,
})
assert(
    explicit_cancelable_result.ok == true,
    "explicit terminal results should not be downgraded to handles by cancel methods"
)
for _, entry in ipairs(log.entries()) do
    assert(
        entry.message ~= "provider returned ambiguous handle/result table",
        "explicit terminal results should not log ambiguous-handle warnings"
    )
end

vim.cmd("qa!")
