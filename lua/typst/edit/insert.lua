local edit_context = require("typst.edit.context")

local M = {}

local templates = {
    strong = {
        text = "**",
        cursor_offset = -1,
        label = "strong markup",
    },
    emph = {
        text = "__",
        cursor_offset = -1,
        label = "emphasis markup",
    },
    math = {
        text = "$  $",
        cursor_offset = -2,
        label = "inline equation",
    },
    content = {
        text = "[]",
        cursor_offset = -1,
        label = "content brackets",
    },
    code = {
        text = "#{}",
        cursor_offset = -1,
        label = "code expression",
    },
    raw = {
        text = "``",
        cursor_offset = -1,
        label = "raw text",
    },
}

local aliases = {
    bold = "strong",
    equation = "math",
    inline_equation = "math",
    italic = "emph",
    italics = "emph",
}

local function copy_template(spec)
    return {
        text = spec.text,
        cursor_offset = spec.cursor_offset,
        label = spec.label,
    }
end

local function normalize_kind(kind)
    kind = kind or "math"
    kind = aliases[kind] or kind

    if not templates[kind] then
        error(("typst.nvim: unknown insert helper %q"):format(kind))
    end

    return kind
end

local function split_text(text)
    return vim.split(text, "\n", { plain = true })
end

local function end_position(start_row, start_col, lines)
    if #lines == 1 then
        return start_row, start_col + #lines[1]
    end

    return start_row + #lines - 1, #lines[#lines]
end

function M.kinds()
    local names = vim.tbl_keys(templates)
    table.sort(names)
    return names
end

function M.template(kind)
    return copy_template(templates[normalize_kind(kind)])
end

function M.insert(kind, opts)
    opts = opts or {}
    kind = normalize_kind(kind)
    local spec = templates[kind]
    local ctx, reason = edit_context.resolve(opts)
    if not ctx then
        return {
            ok = false,
            reason = reason or "position_required",
            message = "No Typst insert position found",
        }
    end
    local row = ctx.row
    local col = ctx.col
    local lines = split_text(spec.text)

    vim.api.nvim_buf_set_text(ctx.bufnr, row, col, row, col, lines)

    local target_row, target_col = end_position(row, col, lines)
    target_col = target_col + (spec.cursor_offset or 0)
    target_row, target_col =
        edit_context.clamp_position(ctx.bufnr, target_row, target_col)
    local cursor_moved = edit_context.set_cursor(ctx, target_row, target_col)
    return {
        ok = true,
        action = "insert",
        bufnr = ctx.bufnr,
        kind = kind,
        text = spec.text,
        label = spec.label,
        row = target_row,
        col = target_col,
        cursor_moved = cursor_moved,
    }
end

function M.strong(opts)
    return M.insert("strong", opts)
end

function M.emph(opts)
    return M.insert("emph", opts)
end

function M.math(opts)
    return M.insert("math", opts)
end

function M.content(opts)
    return M.insert("content", opts)
end

function M.code(opts)
    return M.insert("code", opts)
end

function M.raw(opts)
    return M.insert("raw", opts)
end

return M
