local calls = require("typst.edit.calls")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local ts = require("typst.edit.treesitter")

local M = {}

local call_name = calls.call_name
local content_body_range = calls.content_body_range
local content_node = calls.content_node
local find_call = calls.find_call
local node_text = calls.node_text
local parent_code_range_for_call = calls.parent_code_range_for_call
local range_text = calls.range_text

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

local function strip_content_brackets(bufnr, content)
    local body = content_body_range(content)
    if not body then
        return nil
    end

    return range_text(bufnr, body)
end

local function find_markup(bufnr, node_type, opts)
    opts = opts or {}
    return ts.find_containing(bufnr, node_type, cursor_pos(bufnr, opts))
end

local function markup_body(bufnr, node)
    local text = node_text(bufnr, node)
    if #text < 2 then
        return nil
    end

    return text:sub(2, -2)
end

local markup_specs = {
    strong = {
        markup = "strong",
        function_name = "strong",
        delimiter = "*",
        command = "TypstToggleStrong",
        plug = "<Plug>(typst-toggle-strong)",
    },
    emph = {
        markup = "emph",
        function_name = "emph",
        delimiter = "_",
        command = "TypstToggleEmph",
        plug = "<Plug>(typst-toggle-emph)",
    },
}

local function call_matches(bufnr, call, spec)
    return call_name(bufnr, call) == spec.function_name
        and content_node(call) ~= nil
end

local function function_to_markup(bufnr, call, spec)
    local content = content_node(call)
    local body = content and strip_content_brackets(bufnr, content)
    if body == nil then
        return err(
            "invalid_content",
            "The surrounding Typst function content block cannot be converted"
        )
    end

    set_range(
        bufnr,
        parent_code_range_for_call(bufnr, call) or ts.range(call),
        spec.delimiter .. body .. spec.delimiter
    )
    return ok({
        action = "function_to_markup",
        message = ("Converted #%s[...] to Typst markup"):format(
            spec.function_name
        ),
        name = spec.function_name,
    })
end

local function markup_to_function(bufnr, node, spec)
    local body = markup_body(bufnr, node)
    if body == nil then
        return err(
            "invalid_markup",
            "The surrounding Typst markup cannot be converted"
        )
    end

    set_range(
        bufnr,
        ts.range(node),
        ("#%s[%s]"):format(spec.function_name, body)
    )
    return ok({
        action = "markup_to_function",
        message = ("Converted Typst markup to #%s[...]"):format(
            spec.function_name
        ),
        name = spec.function_name,
    })
end

function M.toggle_markup(kind, opts)
    opts = opts or {}
    local spec = markup_specs[kind]
    if not spec then
        local result = err(
            "invalid_markup_kind",
            'Typst markup kind must be "strong" or "emph"'
        )
        notify_result(result, opts)
        return result
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local pos = cursor_pos(bufnr, opts)
    if not pos then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    local markup = find_markup(bufnr, spec.markup, { pos = pos })
    local call = find_call(bufnr, { pos = pos })
    local result

    if call and call_matches(bufnr, call, spec) then
        result = function_to_markup(bufnr, call, spec)
    elseif markup then
        result = markup_to_function(bufnr, markup, spec)
    else
        result = err(
            "no_markup",
            ("No surrounding Typst %s markup or function call found"):format(
                kind
            )
        )
    end

    if result.ok then
        set_repeat((":%s<CR>"):format(spec.command))
    end
    notify_result(result, opts)
    return result
end

function M.toggle_strong(opts)
    return M.toggle_markup("strong", opts)
end

function M.toggle_emph(opts)
    return M.toggle_markup("emph", opts)
end

return M
