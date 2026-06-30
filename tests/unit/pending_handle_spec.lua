local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local pending = require("typst.core.pending")

local completed = {}
local handle = pending.new({
    kind = "unit",
    complete = function(raw)
        return { ok = true, value = raw.value }
    end,
})

handle:on_finish(function(result, finished)
    completed[#completed + 1] = { result = result, handle = finished }
end)

local result = handle.finish({ value = 42 }, "test")
assert(result.ok == true and result.value == 42, "finish should normalize raw")
assert(handle.pending == false, "finish should clear pending")
assert(handle.result == result, "finish should retain the result")
assert(#completed == 1, "on_finish should run once")
assert(completed[1].handle == handle, "on_finish should receive the handle")

local duplicate = handle.finish({ value = 99 }, "duplicate")
assert(duplicate == result, "duplicate finish should keep first result")
assert(#completed == 1, "duplicate finish should not rerun callbacks")

local late = nil
handle.on_finish(function(done)
    late = done
end)
assert(late == result, "late on_finish should run immediately")

local nil_calls = 0
local nil_duplicates = 0
local nil_handle = pending.new({
    kind = "nil-unit",
    complete = function()
        return nil
    end,
    duplicate = function()
        nil_duplicates = nil_duplicates + 1
    end,
})
nil_handle:on_finish(function(done)
    nil_calls = nil_calls + 1
    assert(done == nil, "nil completion should be delivered to callbacks")
end)
assert(nil_handle.finish({ ok = true }, "nil") == nil, "nil result is valid")
assert(nil_handle.pending == false, "nil finish should clear pending")
assert(nil_handle.finished == true, "nil finish should mark handle finished")
local late_nil_called = false
nil_handle:on_finish(function(done)
    late_nil_called = true
    assert(done == nil, "late callback should receive nil completion")
end)
assert(late_nil_called == true, "late nil callback should run immediately")
assert(nil_handle.finish({ again = true }, "duplicate") == nil)
assert(nil_calls == 1, "duplicate nil finish should not rerun callbacks")
assert(nil_duplicates == 1, "duplicate nil finish should be observable")
local nil_stopped, nil_cancel_result = nil_handle:cancel()
assert(nil_stopped == false, "finished nil handle should not cancel")
assert(nil_cancel_result == nil, "finished nil handle should return nil result")

local cancelled_source_opts = nil
local cancellable = pending.new({
    kind = "cancel-unit",
    handle = {
        cancel = function(_, opts)
            cancelled_source_opts = opts
            return true, { ok = false, stopped = true, reason = opts.reason }
        end,
    },
})

local stopped, cancel_result = cancellable.cancel({ reason = "unit_cancel" })
assert(stopped == true, "cancel should report stopped")
assert(
    cancel_result.reason == "unit_cancel",
    "cancel should finish with source result"
)
assert(
    cancelled_source_opts and cancelled_source_opts.reason == "unit_cancel",
    "cancel should pass options to source handle"
)

local cancel_throwing = pending.new({
    kind = "cancel-throwing",
    cancel = function()
        error("boom")
    end,
})
local cancel_stopped, cancel_failed = cancel_throwing:cancel()
assert(cancel_stopped == false, "throwing cancel should report not stopped")
assert(
    cancel_failed and cancel_failed.reason == "cancel_failed",
    "throwing cancel should normalize to cancel_failed"
)
assert(
    cancel_throwing.finished == true,
    "throwing cancel should still finish the handle"
)

local subscribed = pending.new({ kind = "subscribe-source" })
local observed = nil
local ok = pending.subscribe(subscribed, function(done)
    observed = done
end)
assert(ok == true, "subscribe should accept helper handles")
subscribed.finish({ ok = true, subscribed = true })
assert(
    observed and observed.subscribed == true,
    "subscribe should forward source completion"
)

local dot_callbacks = {}
local dot_source = {
    pending = true,
    on_finish = function(callback)
        dot_callbacks[#dot_callbacks + 1] = callback
    end,
}
ok = pending.subscribe(dot_source, function(done)
    observed = done
end, { style = "dot" })
assert(ok == true, "subscribe should accept dot-style on_finish handles")
assert(#dot_callbacks == 1, "dot-style on_finish should receive callback")
dot_callbacks[1]({ ok = true, dot_style = true })
assert(
    observed and observed.dot_style == true,
    "subscribe should forward dot-style source completion"
)

local dot_two_arg_callbacks = {}
local dot_two_arg_source = {
    pending = true,
    on_finish = function(callback, _opts)
        assert(type(callback) == "function", "dot callback must be explicit")
        dot_two_arg_callbacks[#dot_two_arg_callbacks + 1] = callback
    end,
}
local bad_dot_ok = pending.subscribe(dot_two_arg_source, function() end)
assert(
    bad_dot_ok == false,
    "two-argument dot-style on_finish should not be guessed as a method"
)
ok = pending.subscribe(dot_two_arg_source, function(done)
    observed = done
end, { style = "dot" })
assert(ok == true, "explicit dot style should support two-argument handlers")
assert(
    #dot_two_arg_callbacks == 1,
    "explicit dot style should register the callback exactly once"
)
dot_two_arg_callbacks[1]({ ok = true, dot_two_arg = true })
assert(
    observed and observed.dot_two_arg == true,
    "subscribe should forward two-argument dot-style source completion"
)

local colon_callbacks = {}
local colon_source = {
    pending = true,
}
function colon_source:on_finish(callback)
    colon_callbacks[#colon_callbacks + 1] = callback
end
ok = pending.subscribe(colon_source, function(done)
    observed = done
end)
assert(ok == true, "subscribe should accept colon-style on_finish handles")
assert(#colon_callbacks == 1, "colon-style on_finish should receive callback")
colon_callbacks[1]({ ok = true, colon_style = true })
assert(
    observed and observed.colon_style == true,
    "subscribe should forward colon-style source completion"
)

vim.cmd("qa!")
