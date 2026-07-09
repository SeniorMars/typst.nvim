local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local adapter = require("typst.integrations.provider_adapter")
local contract = require("typst.integrations.provider_contract")

local observed = {}

local function provider_for(case_id)
    if case_id == "sync_success" then
        return function()
            return { ok = true, value = "sync" }
        end
    end

    if case_id == "sync_failure" then
        return function()
            return {
                ok = false,
                reason = "provider_failure",
                message = "failed",
            }
        end
    end

    if case_id == "callback_success" then
        return function(_, _, callback)
            callback({ ok = true, value = "callback" })
            return { pending = true }
        end
    end

    if case_id == "callback_failure" then
        return function(_, _, callback)
            callback({
                ok = false,
                reason = "callback_failure",
            })
            return { pending = true }
        end
    end

    if case_id == "returned_pending_handle" then
        return function()
            return {
                pending = true,
                cancel = function()
                    return true, { stopped = true }
                end,
            }
        end
    end

    if case_id == "pending_handle_timeout" then
        return function()
            return {
                pending = true,
                path = "/tmp/typst.nvim-provider-handle.pdf",
                cancel = function(_, opts)
                    observed.pending_handle_timeout_cancel_opts = opts
                    return true, { stopped = true }
                end,
            }
        end
    end

    if case_id == "cancellation_before_completion" then
        return function()
            return {
                pending = true,
                cancel = function(_, opts)
                    observed.cancel_reason = opts and opts.reason
                    return true,
                        {
                            ok = false,
                            stopped = true,
                            reason = observed.cancel_reason,
                        }
                end,
            }
        end
    end

    if case_id == "duplicate_callback" then
        return function(_, _, callback)
            callback({ ok = true, value = 1 })
            callback({ ok = true, value = 2 })
            return { pending = true }
        end
    end

    if case_id == "thrown_provider_error" then
        return function()
            error("provider exploded")
        end
    end

    if case_id == "malformed_nil_result" then
        return function(_, _, callback)
            callback(nil)
            return { pending = true }
        end
    end

    error("unhandled provider SDK fixture case: " .. tostring(case_id))
end

local function invoke_case(case)
    observed[case.id] = {}
    local callbacks = {}
    local result = adapter.invoke(provider_for(case.id), nil, {}, {}, {
        kind = "sdk",
        provider_name = case.id,
        timeout_ms = case.expected == "timeout" and 10 or nil,
        on_result = function(item)
            callbacks[#callbacks + 1] = item
        end,
        return_mode = case.id == "pending_handle_timeout" and "handle" or nil,
    })
    return result, callbacks
end

local function wait_for_callback(callbacks)
    assert(
        vim.wait(1000, function()
            return #callbacks > 0
        end, 5),
        "provider SDK callback did not arrive"
    )
    return callbacks[#callbacks]
end

local seen = {}
for _, case in ipairs(contract.fixture_cases()) do
    seen[case.id] = true
    local result, callbacks = invoke_case(case)

    if case.expected == "ok" then
        assert(result.ok == true, case.id .. " should return success")
    elseif case.expected == "failure" then
        assert(result.ok == false, case.id .. " should fail")
    elseif case.expected == "pending" then
        assert(result.pending == true, case.id .. " should return pending")
    elseif case.expected == "timeout" then
        assert(
            result.pending == true,
            case.id .. " should expose pending handle"
        )
        assert(result.path, case.id .. " should preserve handle metadata")
        local terminal = wait_for_callback(callbacks)
        assert(terminal.reason == "timeout", case.id .. " should time out")
        assert(
            observed.pending_handle_timeout_cancel_opts
                and observed.pending_handle_timeout_cancel_opts.reason
                    == "timeout",
            case.id .. " should pass timeout cancel options"
        )
    elseif case.expected == "cancelled" then
        assert(result.pending == true, case.id .. " should start pending")
        local ok_cancel = result.cancel({ reason = "user_cancelled" })
        assert(ok_cancel, case.id .. " cancel should return true")
        local terminal = wait_for_callback(callbacks)
        assert(
            terminal.reason == "user_cancelled",
            case.id .. " should publish cancel reason"
        )
    elseif case.expected == "first_result" then
        assert(result.value == 1, case.id .. " first result should win")
        assert(#callbacks == 1, case.id .. " should emit one callback")
    elseif case.expected == "provider_error" then
        assert(
            result.reason == "provider_error",
            case.id .. " should normalize thrown errors"
        )
    elseif case.expected == "invalid_result" then
        assert(
            result.reason == "invalid_result",
            case.id .. " should normalize nil results"
        )
    else
        error("unhandled expected fixture outcome: " .. tostring(case.expected))
    end
end

for _, required in ipairs({
    "sync_success",
    "sync_failure",
    "callback_success",
    "callback_failure",
    "returned_pending_handle",
    "pending_handle_timeout",
    "cancellation_before_completion",
    "duplicate_callback",
    "thrown_provider_error",
    "malformed_nil_result",
}) do
    assert(seen[required], "missing provider SDK fixture case: " .. required)
end

local sdk = contract.sdk_contract()
assert(sdk.version == 1, "provider SDK contract should be versioned")
assert(
    vim.tbl_contains(sdk.result_contract.terminal_fields, "ok"),
    "provider SDK contract should document terminal result fields"
)
assert(
    type(sdk.structural_results) == "table",
    "provider SDK contract should document structural result fields"
)
assert(
    type(sdk.conformance_matrix) == "table"
        and type(sdk.conformance_cases) == "table",
    "provider SDK contract should expose provider conformance coverage"
)

for kind, fields in pairs(contract.structural_results()) do
    local field = fields[1]
    local structural_value = field == "diagnostics" and {} or "value"
    local result = adapter.invoke(
        function()
            return { [field] = structural_value }
        end,
        nil,
        {},
        {},
        {
            kind = kind,
            provider_name = kind .. "-structural-result",
            result_fields = fields,
        }
    )
    assert(
        type(result) == "table" and result[field] ~= nil,
        ("provider kind `%s` should accept structural-only `%s` results when opted in"):format(
            kind,
            field
        )
    )
end

vim.cmd("qa!")
