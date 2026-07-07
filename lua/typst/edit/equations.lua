local core = require("typst.edit.equation_core")
local equation_numbering = require("typst.edit.equation_numbering")
local ts = require("typst.core.treesitter")

local M = {}

local normalize_bufnr = core.normalize_bufnr
local set_range = core.set_range
local ok = core.ok
local err = core.err
local notify_result = core.notify_result
local set_repeat = core.set_repeat
local trim = core.trim
local nonempty = core.nonempty
local math_formula = core.math_formula
local find_math = core.find_math
local find_line_math_range = core.find_line_math_range
local inline_equation_text = core.inline_equation_text

local function normalize_inline_formula(text)
    local parts = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local part = trim(line)
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end

    return table.concat(parts, " ")
end

local function convert_block_equation(bufnr, node)
    local formula = normalize_inline_formula(math_formula(bufnr, node))
    if formula == "" then
        return err(
            "empty_equation",
            "The surrounding Typst equation has no formula content"
        )
    end

    set_range(bufnr, ts.range(node), ("$%s$"):format(formula))
    return ok({
        action = "equation_inline",
        message = "Converted Typst equation to inline form",
        style = "inline",
    })
end

local function convert_inline_equation(bufnr, node)
    local formula = trim(math_formula(bufnr, node))
    if formula == "" then
        return err(
            "empty_equation",
            "The surrounding Typst equation has no formula content"
        )
    end

    local range = ts.range(node)
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    local before = line:sub(1, range.start_col)
    local after = line:sub(range.end_col + 1)
    local indent = before:match("^%s*") or ""
    local lines = {}

    if nonempty(before) then
        lines[#lines + 1] = before:gsub("%s+$", "")
    end

    lines[#lines + 1] = indent .. "$"
    for formula_line in formula:gmatch("[^\n]+") do
        local trimmed = trim(formula_line)
        if trimmed ~= "" then
            lines[#lines + 1] = indent .. "  " .. trimmed
        end
    end
    lines[#lines + 1] = indent .. "$"

    if nonempty(after) then
        lines[#lines + 1] = after:gsub("^%s+", "")
    end

    vim.api.nvim_buf_set_lines(
        bufnr,
        range.start_row,
        range.end_row + 1,
        false,
        lines
    )
    return ok({
        action = "equation_block",
        message = "Converted Typst equation to block form",
        style = "block",
    })
end

local function convert_inline_equation_range(bufnr, range)
    local formula = trim(inline_equation_text(bufnr, range))
    if formula == "" then
        return err(
            "empty_equation",
            "The surrounding Typst equation has no formula content"
        )
    end

    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    local before = line:sub(1, range.start_col)
    local after = line:sub(range.end_col + 1)
    local indent = before:match("^%s*") or ""
    local lines = {}

    if nonempty(before) then
        lines[#lines + 1] = before:gsub("%s+$", "")
    end

    lines[#lines + 1] = indent .. "$"
    lines[#lines + 1] = indent .. "  " .. formula
    lines[#lines + 1] = indent .. "$"

    if nonempty(after) then
        lines[#lines + 1] = after:gsub("^%s+", "")
    end

    vim.api.nvim_buf_set_lines(
        bufnr,
        range.start_row,
        range.end_row + 1,
        false,
        lines
    )
    return ok({
        action = "equation_block",
        message = "Converted Typst equation to block form",
        style = "block",
    })
end

function M.convert_equation(style, opts)
    opts = opts or {}
    style = style or "toggle"
    if style ~= "toggle" and style ~= "inline" and style ~= "block" then
        error(
            'typst.nvim: equation style must be "toggle", "inline", or "block"'
        )
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local node = find_math(bufnr, opts)
    if not node then
        local range = find_line_math_range(bufnr, opts)
        local target = style == "toggle" and "block" or style
        local result = nil
        if range and target == "block" then
            result = convert_inline_equation_range(bufnr, range)
        elseif range and target == "inline" then
            result = err(
                "already_inline",
                "The surrounding Typst equation is already inline"
            )
        else
            result = err("no_equation", "No surrounding Typst equation found")
        end

        if result.ok then
            set_repeat((":TypstConvertEquation %s<CR>"):format(style))
        end
        notify_result(result, opts)
        return result
    end

    local range = ts.range(node)
    local is_inline = range.start_row == range.end_row
    local target = style
    if target == "toggle" then
        target = is_inline and "block" or "inline"
    end

    if target == "inline" and is_inline then
        local result = err(
            "already_inline",
            "The surrounding Typst equation is already inline"
        )
        notify_result(result, opts)
        return result
    end
    if target == "block" and not is_inline then
        local result = err(
            "already_block",
            "The surrounding Typst equation is already a block"
        )
        notify_result(result, opts)
        return result
    end

    local result = target == "inline" and convert_block_equation(bufnr, node)
        or convert_inline_equation(bufnr, node)
    if result.ok then
        set_repeat((":TypstConvertEquation %s<CR>"):format(style))
    end
    notify_result(result, opts)
    return result
end

function M.toggle_equation_numbering(style, opts)
    return equation_numbering.toggle(style, opts)
end

return M
