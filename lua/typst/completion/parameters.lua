local completion_items = require("typst.completion.items")
local completion_match = require("typst.completion.match")
local parameter_context = require("typst.completion.parameter_context")
local parameter_format = require("typst.completion.parameter_format")
local parameter_values = require("typst.completion.parameter_values")
local position = require("typst.completion.position")

local M = {}

local normalize_bufnr = parameter_context.normalize_bufnr

local function cursor_position(opts, bufnr)
    local resolved = position.resolve(opts, bufnr)
    if not resolved then
        return nil
    end
    return resolved.row, resolved.col
end

local function explicit_position(opts, row, col)
    if row and col then
        return row, col
    end
    if opts.function_name then
        local pos = opts.pos or {}
        return pos[1] or 0, pos[2] or 0
    end
end

--- Return named-parameter completions for the current function call.
---@param opts table Completion options, including buffer and optional function name.
---@param base string Completion prefix.
---@return table[] items Parameter completion items.
function M.items(opts, base)
    local bufnr = normalize_bufnr(opts.bufnr)
    local row, col = cursor_position(opts, bufnr)
    row, col = explicit_position(opts, row, col)
    if not row or not col then
        return {}
    end

    local info
    if opts.function_name then
        local lookup_row = opts.pos and row or nil
        local result = parameter_context.function_result(
            bufnr,
            opts.function_name,
            lookup_row
        )
        if result and result.kind == "function" then
            info = {
                name = opts.function_name,
                result = parameter_context.result_for_call_context(result, {
                    set_rule = opts.set_rule == true
                        or opts.settable_only == true,
                }),
                set_rule = opts.set_rule == true or opts.settable_only == true,
            }
        end
    else
        info = parameter_context.parameter_info(bufnr, row, col)
    end

    if not info or not info.result then
        return {}
    end

    local used =
        parameter_context.used_named_arguments(bufnr, row, col, info.call)
    local items = {}
    local seen = {}
    for _, param in ipairs(info.result.parameters or {}) do
        if param.named and not used[param.name] then
            completion_items.add_unique(items, seen, param.name, function()
                return parameter_format.parameter_item(param, info.result)
            end, { base = base, trim = false })
        end
    end

    table.sort(items, function(a, b)
        return a.word < b.word
    end)
    return items
end

--- Return value completions for the current function parameter.
---@param opts table Completion options, including buffer and optional parameter name.
---@param base string Completion prefix.
---@return table[] items Parameter-value completion items.
function M.value_items(opts, base)
    local bufnr = normalize_bufnr(opts.bufnr)
    local row, col = cursor_position(opts, bufnr)
    row, col = explicit_position(opts, row, col)
    if not row or not col then
        return {}
    end

    local info
    if opts.function_name and opts.parameter_name then
        local lookup_row = opts.pos and row or nil
        local result = parameter_context.function_result(
            bufnr,
            opts.function_name,
            lookup_row
        )
        result = parameter_context.result_for_call_context(result, {
            set_rule = opts.set_rule == true or opts.settable_only == true,
        })
        local param =
            parameter_context.find_parameter(result, opts.parameter_name)
        if result and param then
            info = {
                name = opts.function_name,
                result = result,
                parameter = param,
                parameter_name = opts.parameter_name,
                quoted = opts.quoted == true,
                set_rule = opts.set_rule == true or opts.settable_only == true,
            }
        end
    else
        info = parameter_context.value_info(bufnr, row, col)
    end

    if not info or not info.result or not info.parameter then
        return {}
    end

    local candidates = parameter_values.candidates(info.parameter.input)
    local items = {}
    local seen = {}
    for _, candidate in ipairs(candidates) do
        local candidate_base =
            parameter_format.strip_wrapping_quotes(candidate.word)
        completion_items.add_unique(items, seen, candidate.word, function()
            return parameter_format.value_item(candidate, info)
        end, {
            base = base,
            trim = false,
            match = function()
                return completion_match.prefix(candidate.word, base)
                    or completion_match.prefix(candidate_base, base)
                    or (
                        info.value_base
                        and completion_match.prefix(
                            candidate_base,
                            info.value_base
                        )
                    )
            end,
        })
    end

    table.sort(items, function(a, b)
        return a.word < b.word
    end)
    return items
end

--- Check whether a cursor position is inside a named-parameter context.
---@param bufnr integer Buffer to inspect.
---@param row integer Zero-based row.
---@param col integer Zero-based byte column.
---@return boolean active True when parameter-name completions are relevant.
function M.context(bufnr, row, col)
    return parameter_context.parameter_info(bufnr, row, col) ~= nil
end

--- Check whether a cursor position is inside a parameter-value context.
---@param bufnr integer Buffer to inspect.
---@param row integer Zero-based row.
---@param col integer Zero-based byte column.
---@return boolean active True when parameter-value completions are relevant.
function M.value_context(bufnr, row, col)
    return parameter_context.value_info(bufnr, row, col) ~= nil
end

--- Return signature help metadata for the current function call.
---@param opts? table Signature options, including buffer and position.
---@return table? signature Signature help payload, or nil outside a call.
function M.signature(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local resolved = position.resolve(opts, bufnr)
    if not resolved then
        return nil
    end
    local pos = { resolved.row, resolved.col }

    local sig = parameter_context.signature_info(bufnr, pos)
    if not sig then
        return nil
    end

    return {
        label = sig.result.signature,
        active_parameter = parameter_context.active_parameter(
            bufnr,
            sig.call,
            pos
        ),
        parameters = sig.result.parameters or {},
        result = sig.result,
    }
end

return M
