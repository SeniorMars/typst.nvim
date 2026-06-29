local calls = require("typst.edit.calls")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local ts = require("typst.edit.treesitter")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

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

local function set_repeat(keys)
    edit_repeat.set(keys)
end

local function label_name_from_source(source)
    if type(source) ~= "string" then
        return nil
    end

    return source:match("^<([^%s<>]+)>$")
end

local function string_label_name_from_source(source)
    if type(source) ~= "string" then
        return nil
    end

    return source:match('^"([^"\\]*)"$')
end

local function reference_name_from_source(source)
    if type(source) ~= "string" then
        return nil
    end

    return source:match("^@([%w_.:/%-]+)$")
end

local function single_call_argument(bufnr, call)
    local group = calls.group_node(call)
    if not group then
        return nil, "no_argument_group"
    end

    local args, _, has_comment = calls.group_arguments(bufnr, group)
    if has_comment then
        return nil, "comments_present"
    end
    if #args ~= 1 then
        return nil, "unsupported_arguments"
    end

    return args[1], nil
end

local function explicit_label_call_name(bufnr, call)
    local arg, reason = single_call_argument(bufnr, call)
    if not arg then
        return nil, reason
    end

    if arg.type == "label" then
        return label_name_from_source(arg.text), nil
    end
    if arg.type == "string" then
        return string_label_name_from_source(arg.text), nil
    end

    return nil, "unsupported_argument"
end

local function explicit_reference_call_name(bufnr, call)
    local arg, reason = single_call_argument(bufnr, call)
    if not arg then
        return nil, reason
    end

    if arg.type ~= "label" then
        return nil, "unsupported_argument"
    end

    return label_name_from_source(arg.text), nil
end

local function replace_call_source(bufnr, call, replacement)
    set_range(
        bufnr,
        calls.parent_code_range_for_call(bufnr, call) or ts.range(call),
        replacement
    )
end

local function find_shorthand_node(bufnr, node_type, opts)
    opts = opts or {}
    return ts.find_containing(bufnr, node_type, cursor_pos(bufnr, opts))
end

local function is_group_call_argument(node)
    local parent = node and node:parent() or nil
    local grandparent = parent and parent:parent() or nil
    if
        parent
        and parent:type() == "arguments"
        and grandparent
        and grandparent:type() == "function_call"
    then
        return true
    end

    return false
end

function M.toggle_label(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call = calls.find_named_call(bufnr, "label", opts)

    if call then
        local name, reason = explicit_label_call_name(bufnr, call)
        if not name then
            local messages = {
                comments_present = "Typst label calls with comments are not toggled automatically",
                no_argument_group = "The surrounding Typst label call has no argument group",
                unsupported_argument = "The surrounding Typst label call must use a label or plain string argument",
                unsupported_arguments = "The surrounding Typst label call must have exactly one argument",
            }
            local result = err(
                reason or "unsupported_argument",
                messages[reason] or messages.unsupported_argument
            )
            notify_result(result, opts)
            return result
        end

        replace_call_source(bufnr, call, ("<%s>"):format(name))
        local result = ok({
            action = "label_shorthand",
            message = "Converted Typst label to shorthand form",
            name = name,
            style = "shorthand",
        })
        set_repeat(":TypstToggleLabel<CR>")
        notify_result(result, opts)
        return result
    end

    local node = find_shorthand_node(bufnr, "label", opts)
    if not node then
        local result = err("no_label", "No surrounding Typst label found")
        notify_result(result, opts)
        return result
    end

    local source = calls.node_text(bufnr, node)
    local name = label_name_from_source(source)
    if not name then
        local result = err(
            "unsupported_label",
            "The surrounding Typst label cannot be toggled automatically"
        )
        notify_result(result, opts)
        return result
    end
    if is_group_call_argument(node) then
        local result = err(
            "label_argument",
            "Typst label arguments inside function calls are not label definitions"
        )
        notify_result(result, opts)
        return result
    end

    set_range(bufnr, ts.range(node), ("#label(<%s>)"):format(name))
    local result = ok({
        action = "label_explicit",
        message = "Converted Typst label to explicit form",
        name = name,
        style = "explicit",
    })
    set_repeat(":TypstToggleLabel<CR>")
    notify_result(result, opts)
    return result
end

function M.toggle_reference(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call = calls.find_named_call(bufnr, "ref", opts)

    if call then
        local name, reason = explicit_reference_call_name(bufnr, call)
        if not name then
            local messages = {
                comments_present = "Typst ref calls with comments are not toggled automatically",
                no_argument_group = "The surrounding Typst ref call has no argument group",
                unsupported_argument = "The surrounding Typst ref call must use a label argument",
                unsupported_arguments = "The surrounding Typst ref call must have exactly one argument",
            }
            local result = err(
                reason or "unsupported_argument",
                messages[reason] or messages.unsupported_argument
            )
            notify_result(result, opts)
            return result
        end

        replace_call_source(bufnr, call, ("@%s"):format(name))
        local result = ok({
            action = "reference_shorthand",
            message = "Converted Typst reference to shorthand form",
            name = name,
            style = "shorthand",
        })
        set_repeat(":TypstToggleReference<CR>")
        notify_result(result, opts)
        return result
    end

    local node = find_shorthand_node(bufnr, "reference", opts)
    if not node then
        local result =
            err("no_reference", "No surrounding Typst reference found")
        notify_result(result, opts)
        return result
    end

    local source = calls.node_text(bufnr, node)
    local name = reference_name_from_source(source)
    if not name then
        local result = err(
            "unsupported_reference",
            "The surrounding Typst reference cannot be toggled automatically"
        )
        notify_result(result, opts)
        return result
    end

    set_range(bufnr, ts.range(node), ("#ref(<%s>)"):format(name))
    local result = ok({
        action = "reference_explicit",
        message = "Converted Typst reference to explicit form",
        name = name,
        style = "explicit",
    })
    set_repeat(":TypstToggleReference<CR>")
    notify_result(result, opts)
    return result
end

function M.toggle_label_reference(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    if
        calls.find_named_call(bufnr, "ref", opts)
        or find_shorthand_node(bufnr, "reference", opts)
    then
        return M.toggle_reference(opts)
    end
    if
        calls.find_named_call(bufnr, "label", opts)
        or find_shorthand_node(bufnr, "label", opts)
    then
        return M.toggle_label(opts)
    end

    local result = err(
        "no_label_or_reference",
        "No surrounding Typst label or reference found"
    )
    notify_result(result, opts)
    return result
end

return M
