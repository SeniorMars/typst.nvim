local calls = require("typst.edit.calls")
local notify = require("typst.core.notify")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local ts = require("typst.edit.treesitter")

local M = {}

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

function M.set_range(bufnr, range, replacement)
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

function M.ok(result)
    result.ok = true
    return result
end

function M.err(reason, message)
    return {
        ok = false,
        reason = reason,
        message = message,
    }
end

function M.notify_result(result, opts)
    notify.result(result, {
        notify_false = opts and opts.notify == false,
        success = "Applied Typst transform",
        failure = "Typst transform unavailable",
    })
end

function M.set_repeat(keys)
    edit_repeat.set(keys)
end

function M.trim(text)
    return (text or ""):match("^%s*(.-)%s*$")
end

function M.nonempty(text)
    return type(text) == "string" and text:find("%S") ~= nil
end

function M.equation_node(node)
    if not node then
        return nil
    end
    if node:type() == "equation" then
        return node
    end

    local parent = node:parent()
    if parent and parent:type() == "equation" then
        return parent
    end

    return node
end

function M.math_formula(bufnr, node)
    if not node then
        return nil
    end

    if node:type() == "math" then
        return calls.node_text(bufnr, node)
    end

    local formula = calls.first_child(node, "math")
    if not formula then
        return nil
    end

    return calls.node_text(bufnr, formula)
end

function M.find_math(bufnr, opts)
    opts = opts or {}
    return M.equation_node(
        ts.find_containing(
            bufnr,
            { "equation", "math" },
            M.cursor_pos(bufnr, opts)
        )
    )
end

function M.find_line_math_range(bufnr, opts)
    opts = opts or {}
    local pos = M.cursor_pos(bufnr, opts)
    if not pos then
        return nil
    end
    local row = pos[1]
    local col = pos[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local start_index = 1

    while true do
        local start_col = line:find("%$", start_index)
        if not start_col then
            return nil
        end

        local end_col = line:find("%$", start_col + 1)
        if not end_col then
            return nil
        end

        if col >= start_col - 1 and col < end_col then
            return {
                start_row = row,
                start_col = start_col - 1,
                end_row = row,
                end_col = end_col,
            }
        end

        start_index = end_col + 1
    end
end

function M.inline_equation_text(bufnr, range)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    return line:sub(range.start_col + 2, range.end_col - 1)
end

return M
