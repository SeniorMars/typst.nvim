local calls = require("typst.edit.calls")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local surrounding = require("typst.edit.surrounding")
local ts = require("typst.core.treesitter")

local M = {}

local content_body_range = calls.content_body_range
local content_node = calls.content_node
local first_child = calls.first_child
local group_node = calls.group_node
local nested_call_name = calls.nested_call_name
local parent_code_range_for_call = calls.parent_code_range_for_call
local range_span = calls.span
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

local function strip_wrapping_newlines(text)
    text = text or ""
    if text:sub(1, 2) == "\r\n" then
        text = text:sub(3)
    elseif text:sub(1, 1) == "\n" then
        text = text:sub(2)
    end

    if text:sub(-2) == "\r\n" then
        text = text:sub(1, -3)
    elseif text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end

    return text
end

local function find_figure_call(bufnr, opts)
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
            and nested_call_name(bufnr, node) == "figure"
            and (not best or range_span(node) < range_span(best))
        then
            best = node
        end
    end)
    return best
end

local function figure_content_node(call)
    local content = content_node(call)
    if content then
        return content
    end

    local group = group_node(call)
    return group
            and (first_child(group, "content_block") or first_child(
                group,
                "content"
            ))
        or nil
end

local function unwrap_figure(bufnr, call)
    local content = figure_content_node(call)
    if not content then
        return err(
            "no_figure_body",
            "The surrounding Typst figure has no content body to unwrap"
        )
    end

    local body = strip_content_brackets(bufnr, content)
    if body == nil then
        return err(
            "invalid_figure_body",
            "The surrounding Typst figure content cannot be unwrapped"
        )
    end

    set_range(
        bufnr,
        parent_code_range_for_call(bufnr, call) or ts.range(call),
        strip_wrapping_newlines(body)
    )
    return ok({
        action = "figure_unwrap",
        message = "Unwrapped Typst figure",
    })
end

function M.toggle_figure(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call = find_figure_call(bufnr, opts)
    local result

    if call then
        result = unwrap_figure(bufnr, call)
    else
        result = surrounding.wrap_figure(bufnr, opts)
    end

    if result.ok then
        set_repeat(":TypstToggleFigure<CR>")
    end
    notify_result(result, opts)
    return result
end

return M
