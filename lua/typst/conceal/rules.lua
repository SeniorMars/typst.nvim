local log = require("typst.core.log")

local M = {}

local by_capture = {}
local next_order = 0
local logged_errors = {}

local function copy_rule(rule)
    return {
        name = rule.name,
        capture = rule.capture,
        category = rule.category,
        priority = rule.priority or 100,
        resolve = rule.resolve,
        order = rule.order,
    }
end

local function sort_rules(rules)
    table.sort(rules, function(left, right)
        if left.priority ~= right.priority then
            return left.priority > right.priority
        end
        return left.order < right.order
    end)
end

local function validate(rule)
    if type(rule) ~= "table" then
        error("typst.nvim: conceal rule must be a table")
    end
    if type(rule.name) ~= "string" or rule.name == "" then
        error("typst.nvim: conceal rule name must be a non-empty string")
    end
    if type(rule.capture) ~= "string" or rule.capture == "" then
        error("typst.nvim: conceal rule capture must be a non-empty string")
    end
    if rule.category ~= nil and type(rule.category) ~= "string" then
        error("typst.nvim: conceal rule category must be a string")
    end
    if rule.priority ~= nil and type(rule.priority) ~= "number" then
        error("typst.nvim: conceal rule priority must be a number")
    end
    if type(rule.resolve) ~= "function" then
        error("typst.nvim: conceal rule resolve must be a function")
    end
end

local function traceback(err)
    if debug and debug.traceback then
        return debug.traceback(err, 2)
    end
    return err
end

local function log_rule_error(rule, err)
    local key = table.concat({
        rule.capture or "",
        rule.name or "",
        tostring(rule.order or ""),
    }, "\0")
    if logged_errors[key] then
        return
    end
    logged_errors[key] = true
    log.add("warn", "conceal rule failed", {
        capture = rule.capture,
        rule = rule.name,
        error = tostring(err),
    })
end

---Register a capture resolver.
---
---Rules are ordered by descending priority, then registration order. A rule may
---return nil to let the next resolver for the same capture try to produce a
---match. This keeps the query layer declarative while leaving Typst-specific
---safety checks in the resolver modules.
---@param rule {name:string,capture:string,category?:string,priority?:number,resolve:function}
---@return fun():boolean unregister
function M.register(rule)
    validate(rule)

    next_order = next_order + 1
    local entry = copy_rule(rule)
    entry.order = next_order

    local capture_rules = by_capture[entry.capture]
    if not capture_rules then
        capture_rules = {}
        by_capture[entry.capture] = capture_rules
    end
    capture_rules[#capture_rules + 1] = entry
    sort_rules(capture_rules)
    return function()
        return M.unregister(entry)
    end
end

---Unregister a rule entry returned by register internals, or by name/capture.
---@param rule_or_capture table|string
---@param name? string
---@return boolean removed
function M.unregister(rule_or_capture, name)
    local capture
    local order
    if type(rule_or_capture) == "table" then
        capture = rule_or_capture.capture
        name = rule_or_capture.name
        order = rule_or_capture.order
    else
        capture = rule_or_capture
    end

    local capture_rules = capture and by_capture[capture]
    if not capture_rules then
        return false
    end

    for index = #capture_rules, 1, -1 do
        local rule = capture_rules[index]
        if
            (not name or rule.name == name)
            and (not order or rule.order == order)
        then
            table.remove(capture_rules, index)
            if #capture_rules == 0 then
                by_capture[capture] = nil
            end
            return true
        end
    end

    return false
end

---Resolve a Tree-sitter capture through the registered rule chain.
---@param capture string
---@param ctx table
---@param node any
---@return table|nil match
---@return table|nil rule
function M.resolve(capture, ctx, node)
    local capture_rules = by_capture[capture]
    if not capture_rules then
        return nil
    end

    for _, rule in ipairs(capture_rules) do
        local ok, match = xpcall(function()
            return rule.resolve(ctx, node, rule)
        end, traceback)
        if ok and match ~= nil then
            return match, rule
        elseif not ok then
            log_rule_error(rule, match)
        end
    end
end

---Return registered rules for a capture, ordered as they are evaluated.
---@param capture string
---@return table[]
function M.registered(capture)
    local capture_rules = by_capture[capture] or {}
    local result = {}
    for index, rule in ipairs(capture_rules) do
        result[index] = copy_rule(rule)
    end
    return result
end

function M._reset_error_log_for_tests()
    logged_errors = {}
end

return M
