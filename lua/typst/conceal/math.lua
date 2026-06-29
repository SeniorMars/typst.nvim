local conceal_util = require("typst.conceal.util")
local lookup = require("typst.conceal.lookup")
local shadows = require("typst.conceal.shadows")
local syntax = require("typst.conceal.syntax")

local M = {}

local range_from_node = conceal_util.range_from_node
local range_text = conceal_util.range_text
local replacement_safe = conceal_util.replacement_safe
local children = conceal_util.children
local child_count = conceal_util.child_count
local node_text = conceal_util.node_text
local first_child = conceal_util.first_child

local function script_table(opts, operator)
    local maps = lookup.current(nil, opts)
    return operator == "^" and maps.scripts.sup or maps.scripts.sub
end

local function script_label(operator)
    if operator == "^" then
        return "superscript"
    end

    return "subscript"
end

local function script_allowed(opts, char)
    local script_opts = opts.math and opts.math.scripts or {}
    if char:match("^%d$") then
        return script_opts.digits ~= false
    end
    if char == "+" or char == "-" or char == "=" then
        return script_opts.signs ~= false
    end
    if char:match("^%a$") then
        return script_opts.simple_letters ~= false
    end
    if char == "(" or char == ")" then
        return script_opts.grouped == true
    end
    return false
end

local function char_range(range, offset)
    return {
        start_row = range.start_row,
        start_col = range.start_col + offset - 1,
        end_row = range.start_row,
        end_col = range.start_col + offset,
    }
end

local function append_script_part(
    matches,
    bufnr,
    source_range,
    reveal_range,
    opts,
    replacement,
    label,
    operand
)
    local match = syntax.range_match(
        bufnr,
        source_range,
        reveal_range,
        opts,
        "math_scripts",
        replacement,
        "math script",
        ("%s %s"):format(label, operand),
        {
            title = label,
        }
    )
    if match then
        matches[#matches + 1] = match
    end
end

local function append_script_sequence(
    matches,
    bufnr,
    node,
    operator_node,
    operand_node,
    operand,
    opts,
    grouped
)
    local operator = operator_node:type()
    local replacements = script_table(opts, operator)
    local label = script_label(operator)
    local reveal_range = range_from_node(node)
    local operator_range = range_from_node(operator_node)
    local operand_range = range_from_node(operand_node)
    local text = operand
    local content_offset = 0

    if grouped then
        local script_opts = opts.math and opts.math.scripts or {}
        if script_opts.grouped ~= true then
            return
        end
        text = operand:match("^%((.*)%)$")
        if not text or text == "" then
            return
        end
        if
            script_opts.max_group_len
            and script_opts.max_group_len > 0
            and #text > script_opts.max_group_len
        then
            return
        end
        content_offset = 1
    end

    for index = 1, #text do
        local char = text:sub(index, index)
        if not script_allowed(opts, char) or not replacements[char] then
            return
        end
    end

    if #text == 1 and not grouped then
        local source_range = {
            start_row = operator_range.start_row,
            start_col = operator_range.start_col,
            end_row = operand_range.end_row,
            end_col = operand_range.end_col,
        }
        append_script_part(
            matches,
            bufnr,
            source_range,
            reveal_range,
            opts,
            replacements[text],
            label,
            text
        )
        return
    end

    append_script_part(
        matches,
        bufnr,
        operator_range,
        reveal_range,
        opts,
        "",
        label,
        text
    )
    if grouped then
        append_script_part(
            matches,
            bufnr,
            char_range(operand_range, 1),
            reveal_range,
            opts,
            "",
            label,
            text
        )
        append_script_part(
            matches,
            bufnr,
            char_range(operand_range, #operand),
            reveal_range,
            opts,
            "",
            label,
            text
        )
    end

    for index = 1, #text do
        local char = text:sub(index, index)
        append_script_part(
            matches,
            bufnr,
            char_range(operand_range, content_offset + index),
            reveal_range,
            opts,
            replacements[char],
            label,
            text
        )
    end
end

function M.resolve_scripts(bufnr, node, opts)
    if not opts.categories.math_scripts then
        return {}
    end

    local matches = {}
    local node_children = children(node)
    for index = 1, #node_children - 1 do
        local operator_node = node_children[index]
        local operator = operator_node:type()
        if operator == "_" or operator == "^" then
            local operand_node = node_children[index + 1]
            local operand = node_text(bufnr, operand_node) or ""
            if child_count(operand_node) == 0 then
                append_script_sequence(
                    matches,
                    bufnr,
                    node,
                    operator_node,
                    operand_node,
                    operand,
                    opts,
                    false
                )
            elseif operand_node:type() == "math_delimited" then
                append_script_sequence(
                    matches,
                    bufnr,
                    node,
                    operator_node,
                    operand_node,
                    operand,
                    opts,
                    true
                )
            end
        end
    end

    return matches
end

local function call_name_and_content(bufnr, call)
    local ident = first_child(call, "math_identifier")
    local args = first_child(call, "math_arguments")
    if not ident or not args then
        return nil
    end

    local content = first_child(args, "math_sequence")
    if not content then
        return nil
    end

    return node_text(bufnr, ident), content, args, ident
end

local function single_leaf_text(bufnr, node)
    if child_count(node) == 0 then
        return node_text(bufnr, node), node
    end

    local node_children = children(node)
    if #node_children ~= 1 or child_count(node_children[1]) ~= 0 then
        return nil
    end
    return node_text(bufnr, node_children[1]), node_children[1]
end

local function call_shadowed(ctx, name, ident)
    if not name or not ident then
        return false
    end
    return shadows.symbol_shadowed(
        name,
        false,
        ctx.shadow_state or {},
        range_from_node(ident)
    )
end

function M.resolve_font_call(ctx, call)
    local bufnr = ctx.bufnr
    local opts = ctx.opts
    if not opts.categories.math_fonts then
        return nil
    end

    local name, content, _, ident = call_name_and_content(bufnr, call)
    local font_opts = opts.math and opts.math.fonts or {}
    if
        not name
        or font_opts.enabled == false
        or not (font_opts.styles and font_opts.styles[name] == true)
    then
        return nil
    end
    if call_shadowed(ctx, name, ident) then
        return nil
    end

    local text = single_leaf_text(bufnr, content)
    if not text or vim.fn.strchars(text) ~= 1 then
        return nil
    end

    local maps = lookup.current(nil, opts)
    local replacement = maps.fonts[name] and maps.fonts[name][text]
    if not replacement or not replacement_safe(replacement, opts) then
        return nil
    end

    return syntax.node(
        bufnr,
        call,
        opts,
        "math_fonts",
        replacement,
        "math font",
        ("%s %s"):format(name, text)
    )
end

function M.resolve_operator(bufnr, node, opts)
    if not opts.categories.math_operators then
        return nil
    end

    local source = node_text(bufnr, node) or ""
    local maps = lookup.current(nil, opts)
    local replacement = maps.operators[source]
    if not replacement or not replacement_safe(replacement, opts) then
        return nil
    end

    return syntax.node(
        bufnr,
        node,
        opts,
        "math_operators",
        replacement,
        "math operator",
        source
    )
end

function M.resolve_wrapper_call(ctx, call)
    local bufnr = ctx.bufnr
    local opts = ctx.opts
    if not opts.categories.math_wrappers then
        return nil
    end

    local name, content, _, ident = call_name_and_content(bufnr, call)
    if not name then
        return nil
    end

    local maps = lookup.current(nil, opts)
    local wrapper = maps.wrappers[name]
    if not wrapper then
        return nil
    end
    if call_shadowed(ctx, name, ident) then
        return nil
    end

    local call_range = range_from_node(call)
    local content_range = range_from_node(content)
    if call_range.start_row ~= content_range.start_row then
        return nil
    end

    local matches = {}
    local prefix_range = {
        start_row = call_range.start_row,
        start_col = call_range.start_col,
        end_row = content_range.start_row,
        end_col = content_range.start_col,
    }
    local suffix_range = {
        start_row = content_range.end_row,
        start_col = content_range.end_col,
        end_row = call_range.end_row,
        end_col = call_range.end_col,
    }

    local prefix = syntax.range_match(
        bufnr,
        prefix_range,
        call_range,
        opts,
        "math_wrappers",
        wrapper.open,
        "math wrapper",
        wrapper.title,
        { wrapper = name, part = "prefix" }
    )
    if prefix then
        matches[#matches + 1] = prefix
    end

    local suffix = syntax.range_match(
        bufnr,
        suffix_range,
        call_range,
        opts,
        "math_wrappers",
        wrapper.close,
        "math wrapper",
        wrapper.title,
        { wrapper = name, part = "suffix" }
    )
    if suffix then
        matches[#matches + 1] = suffix
    end

    return matches
end

return M
