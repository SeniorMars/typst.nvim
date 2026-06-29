local M = {}

local coordinates = require("typst.core.coordinates")

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.line_before_cursor(bufnr, row, col)
    return coordinates.line_before_cursor(bufnr, row, col)
end

local function parameter_segment(before)
    local segment = before:match("[%(,]%s*([^%(,%[%]{}]*)$") or before
    return segment
end

function M.value_segment(before)
    local segment = parameter_segment(before)
    local name, value = segment:match('^%s*([%w%-]+)%s*:%s*"([^"]*)$')
    if name then
        return name, value, true
    end

    name, value = segment:match("^%s*([%w%-]+)%s*:%s*([%w_.%-]*)$")
    if name then
        return name, value or "", false
    end
end

function M.segment_is_completable(before)
    local segment = parameter_segment(before)
    return not segment:find(":", 1, true)
        and not segment:find('"', 1, true)
        and not segment:find("'", 1, true)
end

function M.function_call_before(before)
    local name = nil
    local start_col = nil
    for candidate_start, candidate in before:gmatch("()([%w_.%-]+)%s*%(") do
        start_col = candidate_start
        name = candidate
    end
    if not name then
        return nil
    end

    local prefix = before:sub(1, start_col - 1)
    return {
        name = name,
        set_rule = prefix:match("#set%s*$") ~= nil,
    }
end

function M.function_call_context(bufnr, row, col)
    local before = M.line_before_cursor(bufnr, row, col)
    if not M.segment_is_completable(before) then
        return nil
    end

    return M.function_call_before(before)
end

function M.function_call_context_for_value(bufnr, row, col)
    return M.function_call_before(M.line_before_cursor(bufnr, row, col))
end

return M
