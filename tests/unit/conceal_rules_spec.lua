local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local match_query = require("typst.conceal.match_query")
local rules = require("typst.conceal.rules")

assert(match_query, "match query module should load built-in conceal rules")

local function has_rule(capture, name)
    for _, rule in ipairs(rules.registered(capture)) do
        if rule.name == name then
            return true
        end
    end
    return false
end

assert(
    has_rule("conceal.symbol", "math_symbols"),
    "symbol captures should be dispatched through the rule registry"
)
assert(
    has_rule("conceal.script", "math_scripts"),
    "script captures should be dispatched through the rule registry"
)
assert(
    has_rule("conceal.function_wrapper", "function_wrappers"),
    "function wrapper captures should be dispatched through the rule registry"
)

local low_called = false
local high_called = false
local unregister_low = rules.register({
    name = "test_low_priority",
    capture = "conceal.test_capture",
    category = "test",
    priority = 10,
    resolve = function()
        low_called = true
        return {
            source = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 },
            replacement = "l",
        }
    end,
})
local unregister_high = rules.register({
    name = "test_high_priority",
    capture = "conceal.test_capture",
    category = "test",
    priority = 20,
    resolve = function()
        high_called = true
        return {
            source = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 },
            replacement = "h",
        }
    end,
})
local match, rule = rules.resolve("conceal.test_capture", {}, {})
assert(match and match.replacement == "h", "higher priority rule should win")
assert(
    rule and rule.name == "test_high_priority",
    "resolved rule should be reported"
)
assert(high_called, "higher priority rule should be called")
assert(not low_called, "lower priority rule should not run after a match")

assert(unregister_high(), "high priority rule should unregister")
match, rule = rules.resolve("conceal.test_capture", {}, {})
assert(
    match and match.replacement == "l",
    "lower priority rule should run after unregister"
)
assert(
    rule and rule.name == "test_low_priority",
    "remaining rule should be reported"
)
assert(unregister_low(), "low priority rule should unregister")
assert(
    rules.resolve("conceal.test_capture", {}, {}) == nil,
    "unregistered capture should not resolve"
)

local fallback_called = false
local unregister_nil = rules.register({
    name = "test_nil_rule",
    capture = "conceal.test_fallback",
    category = "test",
    priority = 20,
    resolve = function()
        return nil
    end,
})
local unregister_fallback = rules.register({
    name = "test_fallback_rule",
    capture = "conceal.test_fallback",
    category = "test",
    priority = 10,
    resolve = function()
        fallback_called = true
        return {
            source = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 },
            replacement = "f",
        }
    end,
})
match, rule = rules.resolve("conceal.test_fallback", {}, {})
assert(
    match and match.replacement == "f" and fallback_called,
    "nil-returning rules should allow lower-priority fallback rules"
)
assert(
    rule and rule.name == "test_fallback_rule",
    "fallback rule should be reported"
)
assert(unregister_nil(), "nil rule should unregister")
assert(unregister_fallback(), "fallback rule should unregister")

local log = require("typst.core.log")
log.clear()
rules._reset_error_log_for_tests()

local throwing_calls = 0
local fallback_after_error_calls = 0
local unregister_throwing = rules.register({
    name = "test_throwing_rule",
    capture = "conceal.test_error",
    category = "test",
    priority = 20,
    resolve = function()
        throwing_calls = throwing_calls + 1
        error("synthetic conceal rule failure")
    end,
})
local unregister_after_error = rules.register({
    name = "test_after_error_rule",
    capture = "conceal.test_error",
    category = "test",
    priority = 10,
    resolve = function()
        fallback_after_error_calls = fallback_after_error_calls + 1
        return {
            source = { start_row = 0, start_col = 0, end_row = 0, end_col = 1 },
            replacement = "e",
        }
    end,
})
match, rule = rules.resolve("conceal.test_error", {}, {})
assert(
    match and match.replacement == "e",
    "throwing conceal rules should fail closed to lower-priority rules"
)
assert(
    rule and rule.name == "test_after_error_rule",
    "fallback rule should be reported after a throwing rule"
)
rules.resolve("conceal.test_error", {}, {})
local rule_errors = 0
for _, entry in ipairs(log.entries()) do
    if entry.message == "conceal rule failed" then
        rule_errors = rule_errors + 1
    end
end
assert(throwing_calls == 2, "throwing rule should still be attempted")
assert(
    fallback_after_error_calls == 2,
    "fallback rule should run after each throwing rule attempt"
)
assert(rule_errors == 1, "throwing rule should be logged once")
assert(unregister_throwing(), "throwing rule should unregister")
assert(unregister_after_error(), "fallback error rule should unregister")

vim.cmd("qa!")
