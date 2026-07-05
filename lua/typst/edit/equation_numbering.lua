local calls = require("typst.edit.calls")
local core = require("typst.edit.equation_core")
local ts = require("typst.edit.treesitter")

local M = {}

local call_name = calls.call_name
local first_child = calls.first_child
local group_node = calls.group_node
local node_text = calls.node_text
local range_span = calls.span

local normalize_bufnr = core.normalize_bufnr
local cursor_pos = core.cursor_pos
local set_range = core.set_range
local ok = core.ok
local err = core.err
local notify_result = core.notify_result
local set_repeat = core.set_repeat
local trim = core.trim
local find_math = core.find_math
local find_line_math_range = core.find_line_math_range

local function find_math_equation_call(bufnr, opts)
    opts = opts or {}
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local root = ts.root(bufnr)
    if not root then
        return nil
    end

    local best = nil
    ts.walk(root, function(node)
        if
            node:type() == "function_call"
            and ts.contains(node, pos[1], pos[2])
            and call_name(bufnr, node) == "math.equation"
            and (not best or range_span(node) < range_span(best))
        then
            best = node
        end
    end)
    return best
end

local function find_line_math_equation_call(bufnr, opts)
    opts = opts or {}
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local row = pos[1]
    local col = pos[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local start_col = line:find("#?math%.equation%s*%(")
    if not start_col then
        return nil
    end

    local end_col = line:find("%)%s*$", start_col) or #line
    if col < start_col - 1 or col >= end_col then
        return nil
    end

    return {
        row = row,
        start_col = start_col - 1,
        end_col = end_col,
    }
end

local function named_argument_value_node(argument)
    local after_colon = false
    for _, child in ipairs(ts.children(argument)) do
        local node_type = child:type()
        if node_type == ":" then
            after_colon = true
        elseif after_colon then
            return child
        elseif node_type ~= "identifier" then
            return child
        end
    end
end

local function tagged_argument(bufnr, group, name)
    if not group then
        return nil, nil
    end

    for _, child in ipairs(ts.children(group)) do
        if child:type() == "named_argument" then
            local ident = first_child(child, "identifier")
            if ident and node_text(bufnr, ident) == name then
                return child, named_argument_value_node(child)
            end
        end
    end
end

local function normalize_equation_numbering_style(style)
    style = style or "toggle"
    if style == "numbered" or style == "enable" then
        return "on"
    elseif style == "unnumbered" or style == "disable" then
        return "off"
    end

    if style == "toggle" or style == "on" or style == "off" then
        return style
    end

    return nil
end

local function equation_numbering_source(opts)
    local value = opts.numbering or opts.pattern or '"(1)"'
    if type(value) ~= "string" or trim(value) == "" then
        value = '"(1)"'
    end

    value = trim(value)
    if value == "none" or value:sub(1, 1) == '"' or value:sub(1, 1) == "{" then
        return value
    end

    return ("%q"):format(value)
end

local function equation_numbering_target(style, enabled)
    if style == "toggle" then
        return not enabled
    end

    return style == "on"
end

local function insert_equation_numbering_arg(bufnr, group, source)
    local range = ts.range(group)
    local insert = {
        start_row = range.start_row,
        start_col = range.start_col + 1,
        end_row = range.start_row,
        end_col = range.start_col + 1,
    }

    set_range(bufnr, insert, ("numbering: %s, "):format(source))
end

local function toggle_equation_call_numbering(bufnr, call, style, opts)
    local group = group_node(call)
    if not group then
        return err(
            "no_equation_arguments",
            "The surrounding Typst equation call has no argument group"
        )
    end

    local _, value = tagged_argument(bufnr, group, "numbering")
    local enabled = value and trim(node_text(bufnr, value)) ~= "none" or false
    local target = equation_numbering_target(style, enabled)
    local source = target and equation_numbering_source(opts) or "none"

    if value then
        set_range(bufnr, ts.range(value), source)
    else
        insert_equation_numbering_arg(bufnr, group, source)
    end

    return ok({
        action = target and "equation_numbering_on" or "equation_numbering_off",
        message = target and "Enabled Typst equation numbering"
            or "Disabled Typst equation numbering",
        style = target and "on" or "off",
        source = source,
    })
end

local function toggle_line_equation_call_numbering(bufnr, call, style, opts)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        call.row,
        call.row + 1,
        false
    )[1] or ""
    local source_start, _, value_start, value, value_end =
        line:find("numbering%s*:%s*()([^,%)]*)()", call.start_col + 1)
    local enabled = value and trim(value) ~= "none" or false
    local target = equation_numbering_target(style, enabled)
    local source = target and equation_numbering_source(opts) or "none"

    if value then
        set_range(bufnr, {
            start_row = call.row,
            start_col = value_start - 1,
            end_row = call.row,
            end_col = value_end - 1,
        }, source)
    else
        local open_col = line:find("%(", call.start_col + 1)
        if not open_col then
            return err(
                "no_equation_arguments",
                "The surrounding Typst equation call has no argument group"
            )
        end
        set_range(bufnr, {
            start_row = call.row,
            start_col = open_col,
            end_row = call.row,
            end_col = open_col,
        }, ("numbering: %s, "):format(source))
    end

    return ok({
        action = target and "equation_numbering_on" or "equation_numbering_off",
        message = target and "Enabled Typst equation numbering"
            or "Disabled Typst equation numbering",
        style = target and "on" or "off",
        source = source,
        start_col = source_start and source_start - 1 or call.start_col,
    })
end

local function toggle_math_syntax_numbering(bufnr, node, style, opts)
    local target = equation_numbering_target(style, false)
    local source = target and equation_numbering_source(opts) or "none"
    local replacement = ("#math.equation(numbering: %s, %s)"):format(
        source,
        node_text(bufnr, node)
    )

    set_range(bufnr, ts.range(node), replacement)
    return ok({
        action = target and "equation_numbering_on" or "equation_numbering_off",
        message = target and "Enabled Typst equation numbering"
            or "Disabled Typst equation numbering",
        style = target and "on" or "off",
        source = source,
    })
end

local function toggle_line_math_syntax_numbering(bufnr, range, style, opts)
    local target = equation_numbering_target(style, false)
    local source = target and equation_numbering_source(opts) or "none"
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    local source_text = line:sub(range.start_col + 1, range.end_col)
    local replacement = ("#math.equation(numbering: %s, %s)"):format(
        source,
        source_text
    )

    set_range(bufnr, range, replacement)
    return ok({
        action = target and "equation_numbering_on" or "equation_numbering_off",
        message = target and "Enabled Typst equation numbering"
            or "Disabled Typst equation numbering",
        style = target and "on" or "off",
        source = source,
    })
end

function M.toggle(style, opts)
    opts = opts or {}
    style = normalize_equation_numbering_style(style)
    if not style then
        error(
            'typst.nvim: equation numbering style must be "toggle", "on", or "off"'
        )
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local call = find_math_equation_call(bufnr, opts)
    local result

    if call then
        result = toggle_equation_call_numbering(bufnr, call, style, opts)
    else
        local line_call = find_line_math_equation_call(bufnr, opts)
        if line_call then
            result = toggle_line_equation_call_numbering(
                bufnr,
                line_call,
                style,
                opts
            )
        end
    end

    if not result then
        local node = find_math(bufnr, opts)
        if not node then
            local range = find_line_math_range(bufnr, opts)
            result = range
                    and toggle_line_math_syntax_numbering(
                        bufnr,
                        range,
                        style,
                        opts
                    )
                or err("no_equation", "No surrounding Typst equation found")
        else
            result = toggle_math_syntax_numbering(bufnr, node, style, opts)
        end
    end

    if result.ok then
        set_repeat((":TypstToggleEquationNumbering %s<CR>"):format(style))
    end
    notify_result(result, opts)
    return result
end

return M
