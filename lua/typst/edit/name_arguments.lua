local calls = require("typst.edit.calls")
local edit_repeat = require("typst.edit.repeat")
local name_argument_params = require("typst.edit.name_argument_params")
local ts = require("typst.edit.treesitter")

local M = {}

local call_name = calls.call_name
local find_call_group = calls.find_call_group
local first_child = calls.first_child
local group_arguments = calls.group_arguments
local node_text = calls.node_text

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function set_range(bufnr, range, replacement)
    local lines = vim.split(replacement, "\n", { plain = true })
    vim.api.nvim_buf_set_text(
        bufnr,
        range.start_row,
        range.start_col,
        range.end_row,
        range.end_col,
        lines
    )
end

local function range_offset(base, lines, row, col)
    local line_index = row - base.start_row + 1
    if line_index <= 1 then
        return col - base.start_col
    end

    local offset = 0
    for index = 1, line_index - 1 do
        offset = offset + #(lines[index] or "") + 1
    end
    return offset + col
end

local function ok(result)
    result.ok = true
    return result
end

local function err(reason, message)
    return {
        ok = false,
        reason = reason,
        message = message,
    }
end

local function notify_result(result, opts)
    if opts and opts.notify == false then
        return
    end

    if result.ok then
        vim.notify(
            result.message or "Applied Typst transform",
            vim.log.levels.INFO,
            { title = "typst.nvim" }
        )
    else
        vim.notify(
            result.message or "Typst transform unavailable",
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
    end
end

local function call_is_let_definition(call)
    local parent = call and call:parent() or nil
    return parent and parent:type() == "let_binding"
end

local function parameter_name(bufnr, arg)
    if not arg or not arg.node then
        return nil
    end

    if arg.type == "identifier" then
        return arg.text
    end

    if arg.type == "named_argument" or arg.type == "named_parameter" then
        local ident = first_child(arg.node, "identifier")
        return ident and node_text(bufnr, ident) or nil
    end
end

local function apply_named_argument_edits(bufnr, group, positional)
    local group_range = ts.range(group)
    local lines = vim.api.nvim_buf_get_text(
        bufnr,
        group_range.start_row,
        group_range.start_col,
        group_range.end_row,
        group_range.end_col,
        {}
    )
    local text = table.concat(lines, "\n")
    local edits = {}

    for _, item in ipairs(positional) do
        local range = ts.range(item.arg.node)
        edits[#edits + 1] = {
            start = range_offset(
                group_range,
                lines,
                range.start_row,
                range.start_col
            ),
            finish = range_offset(
                group_range,
                lines,
                range.end_row,
                range.end_col
            ),
            replacement = ("%s: %s"):format(item.name, item.arg.text),
        }
    end

    table.sort(edits, function(left, right)
        return left.start > right.start
    end)

    for _, edit in ipairs(edits) do
        text = text:sub(1, edit.start)
            .. edit.replacement
            .. text:sub(edit.finish + 1)
    end

    set_range(bufnr, group_range, text)
end

function M.name_arguments(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call, group = find_call_group(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
        notify_result(result, opts)
        return result
    end
    if call_is_let_definition(call) then
        local result = err(
            "definition_call",
            "Typst function declarations are not call sites"
        )
        notify_result(result, opts)
        return result
    end
    if not group then
        local result = err(
            "no_argument_group",
            "The surrounding Typst function call has no argument group"
        )
        notify_result(result, opts)
        return result
    end

    local name = call_name(bufnr, call)
    if not name then
        local result = err("no_function_name", "No Typst function name found")
        notify_result(result, opts)
        return result
    end

    local params, param_reason =
        name_argument_params.function_parameters(bufnr, name, call)
    if not params then
        local messages = {
            comments_present = "Typst function declarations with comments are not used for argument naming",
            no_nameable_parameters = "No nameable Typst positional parameters found for this call",
            no_parameter_metadata = "No Typst function parameter names found for this call",
            no_parser = "Typst parser unavailable for local parameter lookup",
            positional_only_parameters = "The Typst function only accepts these positional arguments without names",
            unsupported_parameters = "The local Typst function has unsupported parameter syntax",
            variadic_parameters = "Typst functions with variadic parameters are not named automatically",
        }
        local result = err(
            param_reason or "no_parameter_metadata",
            messages[param_reason] or messages.no_parameter_metadata
        )
        notify_result(result, opts)
        return result
    end

    local args, _, has_comment = group_arguments(bufnr, group)
    if has_comment then
        local result = err(
            "comments_present",
            "Typst argument lists with comments are not edited automatically"
        )
        notify_result(result, opts)
        return result
    end

    local positional = {}
    local seen_named = {}
    local positional_index = 0
    for _, arg in ipairs(args) do
        if arg.type == "named_argument" then
            local tagged_name = parameter_name(bufnr, arg)
            if tagged_name then
                seen_named[tagged_name] = true
            end
        elseif arg.type == "spread_argument" then
            local result = err(
                "spread_argument",
                "Typst spread arguments cannot be converted to named arguments"
            )
            notify_result(result, opts)
            return result
        else
            positional_index = positional_index + 1
            local param_name = params[positional_index]
            if not param_name then
                local result = err(
                    "too_many_arguments",
                    "No Typst parameter name exists for this positional argument"
                )
                notify_result(result, opts)
                return result
            end
            if seen_named[param_name] then
                local result = err(
                    "duplicate_argument",
                    ("Typst argument %s is already named"):format(param_name)
                )
                notify_result(result, opts)
                return result
            end
            positional[#positional + 1] = {
                arg = arg,
                name = param_name,
            }
            seen_named[param_name] = true
        end
    end

    if #positional == 0 then
        local result = err(
            "no_positional_arguments",
            "The surrounding Typst call has no positional arguments to name"
        )
        notify_result(result, opts)
        return result
    end

    apply_named_argument_edits(bufnr, group, positional)

    local result = ok({
        action = "name_arguments",
        message = "Converted Typst positional arguments to named arguments",
        name = name,
        count = #positional,
    })
    edit_repeat.set(":TypstNameArguments<CR>")
    notify_result(result, opts)
    return result
end

return M
