local calls = require("typst.edit.calls")
local edit_repeat = require("typst.edit.repeat")
local name_arguments = require("typst.edit.name_arguments")
local ts = require("typst.edit.treesitter")

local M = {}

local call_name = calls.call_name
local find_call_group = calls.find_call_group
local group_arguments = calls.group_arguments
local group_line_indent = calls.group_line_indent

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

function M.split_arguments(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call, group = find_call_group(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
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

    local range = ts.range(group)
    if range.start_row ~= range.end_row then
        local result = err(
            "already_split",
            "The surrounding Typst argument list is already multiline"
        )
        notify_result(result, opts)
        return result
    end

    local args, _, has_comment = group_arguments(bufnr, group)
    if has_comment then
        local result = err(
            "comments_present",
            "Typst argument lists with comments are not split automatically"
        )
        notify_result(result, opts)
        return result
    end
    if #args == 0 then
        local result = err(
            "empty_arguments",
            "The surrounding Typst argument list has no arguments to split"
        )
        notify_result(result, opts)
        return result
    end

    local indent = group_line_indent(bufnr, group)
    local arg_indent = indent .. "  "
    local lines = { "(" }
    for _, arg in ipairs(args) do
        lines[#lines + 1] = arg_indent .. arg.text .. ","
    end
    lines[#lines + 1] = indent .. ")"

    set_range(bufnr, range, table.concat(lines, "\n"))
    local result = ok({
        action = "split_arguments",
        message = "Split Typst function arguments",
        name = call_name(bufnr, call),
        count = #args,
    })
    set_repeat(":TypstSplitArguments<CR>")
    notify_result(result, opts)
    return result
end

function M.join_arguments(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call, group = find_call_group(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
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

    local range = ts.range(group)
    if range.start_row == range.end_row then
        local result = err(
            "already_joined",
            "The surrounding Typst argument list is already inline"
        )
        notify_result(result, opts)
        return result
    end

    local args, _, has_comment = group_arguments(bufnr, group)
    if has_comment then
        local result = err(
            "comments_present",
            "Typst argument lists with comments are not joined automatically"
        )
        notify_result(result, opts)
        return result
    end

    local parts = {}
    for _, arg in ipairs(args) do
        if arg.text:find("\n", 1, true) then
            local result = err(
                "multiline_argument",
                "Typst argument lists with multiline arguments are not joined automatically"
            )
            notify_result(result, opts)
            return result
        end
        parts[#parts + 1] = arg.text
    end

    set_range(bufnr, range, ("(%s)"):format(table.concat(parts, ", ")))
    local result = ok({
        action = "join_arguments",
        message = "Joined Typst function arguments",
        name = call_name(bufnr, call),
        count = #parts,
    })
    set_repeat(":TypstJoinArguments<CR>")
    notify_result(result, opts)
    return result
end

function M.toggle_arguments(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call, group = find_call_group(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
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

    local range = ts.range(group)
    if range.start_row == range.end_row then
        return M.split_arguments(opts)
    end
    return M.join_arguments(opts)
end

local function normalize_trailing_comma_style(style)
    style = style or "toggle"
    if style == "add" or style == "on" or style == "enable" then
        return "add"
    end
    if style == "remove" or style == "off" or style == "disable" then
        return "remove"
    end
    if style == "toggle" then
        return style
    end
end

local function trailing_comma_target(style, enabled)
    if style == "toggle" then
        return not enabled
    end
    return style == "add"
end

function M.toggle_trailing_comma(style, opts)
    opts = opts or {}
    style = normalize_trailing_comma_style(style)
    if not style then
        error(
            'typst.nvim: trailing comma style must be "toggle", "add", or "remove"'
        )
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local call, group = find_call_group(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
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

    local range = ts.range(group)
    if range.start_row == range.end_row then
        local result = err(
            "not_multiline",
            "Trailing comma edits are only applied to multiline Typst argument lists"
        )
        notify_result(result, opts)
        return result
    end

    local args, trailing_comma, has_comment, trailing_comma_node =
        group_arguments(bufnr, group)
    if has_comment then
        local result = err(
            "comments_present",
            "Typst argument lists with comments are not edited automatically"
        )
        notify_result(result, opts)
        return result
    end
    if #args == 0 then
        local result = err(
            "empty_arguments",
            "The surrounding Typst argument list has no arguments"
        )
        notify_result(result, opts)
        return result
    end

    local target = trailing_comma_target(style, trailing_comma)
    if target and trailing_comma then
        local result = err(
            "already_trailing_comma",
            "The surrounding Typst argument list already has a trailing comma"
        )
        notify_result(result, opts)
        return result
    end
    if not target and not trailing_comma then
        local result = err(
            "no_trailing_comma",
            "The surrounding Typst argument list has no trailing comma"
        )
        notify_result(result, opts)
        return result
    end

    if target then
        local arg_range = ts.range(args[#args].node)
        set_range(bufnr, {
            start_row = arg_range.end_row,
            start_col = arg_range.end_col,
            end_row = arg_range.end_row,
            end_col = arg_range.end_col,
        }, ",")
    else
        set_range(bufnr, ts.range(trailing_comma_node), "")
    end

    local result = ok({
        action = target and "add_trailing_comma" or "remove_trailing_comma",
        message = target and "Added Typst trailing comma"
            or "Removed Typst trailing comma",
        name = call_name(bufnr, call),
        style = target and "add" or "remove",
    })
    set_repeat((":TypstToggleTrailingComma %s<CR>"):format(style))
    notify_result(result, opts)
    return result
end

function M.add_trailing_comma(opts)
    return M.toggle_trailing_comma("add", opts)
end

function M.remove_trailing_comma(opts)
    return M.toggle_trailing_comma("remove", opts)
end

function M.name_arguments(opts)
    return name_arguments.name_arguments(opts)
end

return M
