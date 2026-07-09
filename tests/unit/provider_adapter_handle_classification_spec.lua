local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")
local log = require("typst.core.log")
local operation = require("typst.core.operation")

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
    type(handle) == "table" and handle.reason == "invalid_result",
    "cancelable path tables without pending=true should be invalid"
)

local output_handle = invoke_returning(cancelable({
    output = "/tmp/output.pdf",
}))
assert(
    type(output_handle) == "table"
        and output_handle.reason == "invalid_result",
    "cancelable output tables without pending=true should be invalid"
)

local diagnostics_handle = invoke_returning(cancelable({
    diagnostics = {},
}))
assert(
    type(diagnostics_handle) == "table"
        and diagnostics_handle.reason == "invalid_result",
    "cancelable diagnostics tables without pending=true should be invalid"
)

local by_buffer_handle = invoke_returning(cancelable({
    by_buffer = {},
}))
assert(
    type(by_buffer_handle) == "table"
        and by_buffer_handle.reason == "invalid_result",
    "cancelable by_buffer tables without pending=true should be invalid"
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
        and source_map_handle.reason == "invalid_result",
    "cancelable provider-specific structural tables without pending=true should be invalid"
)

assert(
    callback_called == true,
    "strict-contract violations should complete as invalid results"
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
assert(
    saw_warning == false,
    "strict-contract violations should not be accepted as ambiguous handles"
)

callback_called = false
local explicit_pending_handle = invoke_returning(cancelable({
    pending = true,
    path = "/tmp/output.pdf",
}))
assert(
    explicit_pending_handle.pending == true
        and explicit_pending_handle.path == "/tmp/output.pdf",
    "structural async handles must be explicit pending handles"
)
assert(
    callback_called == false,
    "explicit pending handles should not complete until they produce a result"
)

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

local pending_class = adapter.classify_return({
    pending = true,
    reason = "starting",
    cancel = function()
        return true
    end,
}, {
    return_mode = "handle",
    expect_handle = true,
})
assert(
    pending_class.active_handle == true
        and pending_class.pending == true
        and pending_class.kind == "pending_handle",
    "classification should preserve pending provider handles"
)

local result_class = adapter.classify_return({
    ok = true,
    output = "/tmp/output.pdf",
}, {
    return_mode = "handle",
})
assert(
    result_class.terminal_result == true and result_class.active_handle == false,
    "classification should identify explicit terminal results"
)

local invalid_class = adapter.classify_return("bad-handle", {
    return_mode = "handle",
    expect_handle = true,
})
assert(
    invalid_class.invalid_handle == true
        and invalid_class.active_handle == false,
    "classification should reject scalar handles when a handle is required"
)
assert(
    adapter.is_active_handle("bad-handle", {
        return_mode = "handle",
        expect_handle = true,
    }) == false,
    "invalid scalar handles must not be stored as active lifecycle handles"
)
local structural_invalid_class = adapter.classify_return({
    path = "/tmp/output.pdf",
})
assert(
    structural_invalid_class.invalid_handle == true
        and structural_invalid_class.kind == "invalid_handle",
    "plain structural provider tables should be invalid without explicit ok/result fields"
)
assert(
    adapter.is_active_handle({ pending = true }, { return_mode = "handle" }),
    "is_active_handle should follow adapter classification"
)
assert(
    adapter.is_terminal_result(
        { reason = "failed" },
        { return_mode = "handle" }
    ),
    "is_terminal_result should follow adapter classification"
)

local op = operation.new("provider-adapter-classification")
local operation_class = adapter.classify_return(op, {
    return_mode = "handle",
    expect_handle = true,
})
assert(
    operation_class.active_handle == true
        and operation_class.invalid_handle == false,
    "operation handles should satisfy the shared provider handle contract"
)
op:finish({ ok = true, code = 0 })
local finished_operation_class = adapter.classify_return(op, {
    return_mode = "handle",
    expect_handle = true,
})
assert(
    finished_operation_class.terminal_result == true
        and finished_operation_class.active_handle == false,
    "finished operation handles should classify as terminal results"
)
local structural_with_cancel = {
    path = "/tmp/output.pdf",
    cancel = function()
        return true
    end,
}
local structural_handle_class =
    adapter.classify_return(structural_with_cancel, {
        result_fields = { path = true },
        is_handle = function(value)
            return type(value) == "table"
                and not adapter.result_like(value)
                and type(value.cancel) == "function"
        end,
    })
assert(
    structural_handle_class.active_handle == true
        and structural_handle_class.terminal_result == false,
    "structural cancelable provider tables should remain active handles"
)
assert(
    adapter.is_terminal_result(structural_with_cancel, {
        accept_table_result = true,
        result_fields = { path = true },
        is_handle = function(value)
            return type(value) == "table"
                and not adapter.result_like(value)
                and type(value.cancel) == "function"
        end,
    }) == false,
    "terminal-result helper should preserve caller-provided handle predicates"
)
assert(
    adapter.is_terminal_result({}, {
        accept_table_result = true,
        is_handle = function(value)
            return type(value) == "table"
                and not adapter.result_like(value)
                and type(value.cancel) == "function"
        end,
    }) == true,
    "accept_table_result should preserve legacy plain table terminal results"
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
