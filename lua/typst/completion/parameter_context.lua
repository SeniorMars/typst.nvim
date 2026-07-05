local function_results = require("typst.completion.function_results")
local parameter_parse = require("typst.completion.parameter_parse")
local ts = require("typst.core.treesitter")

local M = {}

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function call_argument_group(call)
    local arguments = call and ts.find_child(call, "arguments") or nil
    return arguments
            and ts.find_child(arguments, "(")
            and ts.find_child(arguments, ")")
            and arguments
        or nil
end

function M.used_named_arguments(bufnr, row, col, call)
    local used = {}

    if call then
        local group = call_argument_group(call)
        if group then
            local ok, text = pcall(vim.treesitter.get_node_text, group, bufnr)
            if ok and type(text) == "string" then
                for name in text:gmatch("([%w%-]+)%s*:") do
                    used[name] = true
                end
            end
        end
    end

    local before = parameter_parse.line_before_cursor(bufnr, row, col)
    for name in before:gmatch("([%w%-]+)%s*:") do
        used[name] = true
    end

    return used
end

function M.function_result(bufnr, name, row)
    return function_results.function_result(bufnr, name, row)
end

function M.result_for_call_context(result, call_context)
    return function_results.result_for_call_context(result, call_context)
end

function M.find_parameter(result, name)
    return function_results.find_parameter(result, name)
end

local call_signature

function M.parameter_info(bufnr, row, col)
    local before = parameter_parse.line_before_cursor(bufnr, row, col)
    if not parameter_parse.segment_is_completable(before) then
        return nil
    end

    local sig = call_signature and call_signature(bufnr, { row, col }) or nil
    if sig and sig.result then
        if sig.group and not ts.contains(sig.group, row, col) then
            return nil
        end

        return sig
    end

    local call = parameter_parse.function_call_context(bufnr, row, col)
    local result = M.function_result(bufnr, call and call.name or nil, row)
    result = M.result_for_call_context(result, call)
    if call and result and result.kind == "function" then
        return {
            name = call.name,
            result = result,
            set_rule = call.set_rule == true,
        }
    end
end

function M.value_info(bufnr, row, col)
    local before = parameter_parse.line_before_cursor(bufnr, row, col)
    local parameter_name, value_base, quoted =
        parameter_parse.value_segment(before)
    if not parameter_name then
        return nil
    end

    local sig = call_signature and call_signature(bufnr, { row, col }) or nil
    if sig and sig.result then
        if sig.group and not ts.contains(sig.group, row, col) then
            return nil
        end

        local param = M.find_parameter(sig.result, parameter_name)
        if param then
            sig.parameter = param
            sig.parameter_name = parameter_name
            sig.value_base = value_base
            sig.quoted = quoted
            return sig
        end
    end

    local call =
        parameter_parse.function_call_context_for_value(bufnr, row, col)
    local result = M.function_result(bufnr, call and call.name or nil, row)
    result = M.result_for_call_context(result, call)
    local param = M.find_parameter(result, parameter_name)
    if call and param then
        return {
            name = call.name,
            result = result,
            parameter = param,
            parameter_name = parameter_name,
            value_base = value_base,
            quoted = quoted,
            set_rule = call.set_rule == true,
        }
    end
end

local function first_name_child(bufnr, node)
    for index = 0, node:child_count() - 1 do
        local child = node:child(index)
        local child_type = child:type()
        if child_type == "identifier" or child_type == "field_access" then
            return vim.treesitter.get_node_text(child, bufnr)
        end
    end
end

local function containing_call(bufnr, pos)
    return ts.find_containing(bufnr, "function_call", pos)
end

local function set_rule_for_call_node(bufnr, call)
    local start_row, start_col = call:range()
    return parameter_parse
        .line_before_cursor(bufnr, start_row, start_col)
        :match("#set%s*$") ~= nil
end

call_signature = function(bufnr, pos)
    local call = containing_call(bufnr, pos)
    local name = call and first_name_child(bufnr, call) or nil
    local set_rule = call and set_rule_for_call_node(bufnr, call) or nil
    if not name then
        local line_call = parameter_parse.function_call_context_for_value(
            bufnr,
            pos[1],
            pos[2]
        )
        name = line_call and line_call.name or nil
        set_rule = line_call and line_call.set_rule or nil
    end
    if not name then
        return nil
    end

    local result = M.function_result(bufnr, name, pos[1])
    if not result or result.kind ~= "function" or not result.signature then
        return nil
    end

    result = M.result_for_call_context(result, { set_rule = set_rule })
    return {
        call = call,
        group = call_argument_group(call),
        name = name,
        result = result,
        set_rule = set_rule,
    }
end

function M.signature_info(bufnr, pos)
    return call_signature(bufnr, pos)
end

function M.active_parameter(bufnr, call, pos)
    if not call then
        return nil
    end

    local group = call_argument_group(call)
    if not group then
        return nil
    end

    local row, col = pos[1], pos[2]
    local active = 0
    for index = 0, group:child_count() - 1 do
        local child = group:child(index)
        local start_row, start_col = child:range()
        if start_row > row or (start_row == row and start_col >= col) then
            break
        end
        if child:type() == "," then
            active = active + 1
        end
    end

    return active
end

return M
