local edit_repeat = require("typst.edit.repeat")
local cursor = require("typst.edit.cursor")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

local function selected_rows(bufnr, opts)
    opts = opts or {}
    if type(opts.start_row) == "number" and type(opts.end_row) == "number" then
        return opts.start_row, opts.end_row
    end

    if
        type(opts.line1) == "number"
        and type(opts.line2) == "number"
        and opts.range
        and opts.range > 0
    then
        return opts.line1 - 1, opts.line2 - 1
    end

    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
        local start_line = vim.fn.line("'<")
        local end_line = vim.fn.line("'>")
        if start_line > 0 and end_line > 0 then
            if start_line > end_line then
                start_line, end_line = end_line, start_line
            end
            return start_line - 1, end_line - 1
        end
    end

    local pos = cursor_pos(bufnr, opts)
    if not pos then
        return nil, nil
    end
    return pos[1], pos[1]
end

local function trim(text)
    return (text or ""):match("^%s*(.-)%s*$")
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

local function first_nonblank_indent(lines)
    for _, line in ipairs(lines) do
        if line:find("%S") then
            return line:match("^%s*") or ""
        end
    end
    return nil
end

function M.wrap_figure(bufnr, opts)
    local start_row, end_row = selected_rows(bufnr, opts)
    if not start_row or not end_row then
        return err("position_required", "No Typst cursor position found")
    end
    start_row = math.max(0, start_row)
    end_row = math.min(vim.api.nvim_buf_line_count(bufnr) - 1, end_row)

    if end_row < start_row then
        return err(
            "invalid_range",
            "No Typst content selected for figure wrapping"
        )
    end

    local lines =
        vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local indent = first_nonblank_indent(lines)
    if not indent then
        return err(
            "empty_range",
            "No non-empty Typst content selected for figure wrapping"
        )
    end

    local replacement = { indent .. "#figure[" }
    vim.list_extend(replacement, lines)
    replacement[#replacement + 1] = indent .. "]"
    vim.api.nvim_buf_set_lines(
        bufnr,
        start_row,
        end_row + 1,
        false,
        replacement
    )
    return ok({
        action = "figure_wrap",
        message = "Wrapped Typst content in a figure",
        start_row = start_row,
        end_row = end_row + 2,
    })
end

local surround_aliases = {
    bracket = "content",
    brackets = "content",
    call = "function",
    code = "block",
    emphasis = "emph",
    eq = "equation",
    func = "function",
    math = "equation",
}

local function normalize_surround_kind(kind)
    if type(kind) ~= "string" then
        return nil
    end

    kind = trim(kind)
    if kind == "" then
        return nil
    end

    return surround_aliases[kind] or kind
end

local function validate_surround_function_name(name)
    if type(name) ~= "string" or trim(name) == "" then
        return nil
    end

    name = trim(name)
    if name:sub(1, 1) == "#" then
        name = name:sub(2)
    end

    for part in name:gmatch("[^%.]+") do
        if not part:match("^[%a_][%w_%-]*$") then
            return nil
        end
    end

    if
        name:sub(1, 1) == "."
        or name:find("%.%.", 1, true)
        or name:sub(-1) == "."
    then
        return nil
    end

    return name
end

local function surround_selection(bufnr, opts, spec)
    local start_row, end_row = selected_rows(bufnr, opts)
    if not start_row or not end_row then
        return err("position_required", "No Typst cursor position found")
    end
    start_row = math.max(0, start_row)
    end_row = math.min(vim.api.nvim_buf_line_count(bufnr) - 1, end_row)

    if end_row < start_row then
        return err(
            "invalid_range",
            ("No Typst content selected for %s surround"):format(spec.kind)
        )
    end

    local lines =
        vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local indent = first_nonblank_indent(lines)
    if not indent then
        return err(
            "empty_range",
            ("No non-empty Typst content selected for %s surround"):format(
                spec.kind
            )
        )
    end

    local replacement
    if spec.inline_single and #lines == 1 then
        local body = lines[1]
        if indent ~= "" and body:sub(1, #indent) == indent then
            body = body:sub(#indent + 1)
        end
        replacement = { indent .. spec.open .. body .. spec.close }
    else
        replacement = { indent .. spec.open }
        vim.list_extend(replacement, lines)
        replacement[#replacement + 1] = indent .. spec.close
    end

    vim.api.nvim_buf_set_lines(
        bufnr,
        start_row,
        end_row + 1,
        false,
        replacement
    )
    return ok({
        action = "surround_" .. spec.kind,
        message = ("Surrounded Typst content with %s"):format(spec.label),
        kind = spec.kind,
        name = spec.name,
        start_row = start_row,
        end_row = start_row + #replacement - 1,
    })
end

local function surround_spec(kind, opts)
    if kind == "content" then
        return {
            kind = kind,
            label = "content brackets",
            open = "[",
            close = "]",
        }
    elseif kind == "equation" then
        return { kind = kind, label = "an equation", open = "$", close = "$" }
    elseif kind == "block" then
        return { kind = kind, label = "a code block", open = "{", close = "}" }
    elseif kind == "strong" then
        return {
            kind = kind,
            label = "strong markup",
            open = "*",
            close = "*",
            inline_single = true,
        }
    elseif kind == "emph" then
        return {
            kind = kind,
            label = "emphasis markup",
            open = "_",
            close = "_",
            inline_single = true,
        }
    elseif kind == "function" then
        local name = validate_surround_function_name(opts.name)
        if not name then
            return nil,
                err(
                    "invalid_name",
                    "Typst surround function name must be a valid function path"
                )
        end
        return {
            kind = kind,
            label = ("#%s[...]"):format(name),
            open = ("#%s["):format(name),
            close = "]",
            name = name,
        }
    end

    return nil,
        err(
            "invalid_surround_kind",
            'Typst surround kind must be "function", "content", "equation", "figure", "block", "strong", or "emph"'
        )
end

function M.surround(kind, opts)
    opts = opts or {}
    kind = normalize_surround_kind(kind)
    local bufnr = normalize_bufnr(opts.bufnr)
    local result

    if kind == "figure" then
        result = M.wrap_figure(bufnr, opts)
        if result.ok then
            result.action = "surround_figure"
            result.kind = "figure"
            result.message = "Surrounded Typst content with a figure"
        end
    else
        local spec, spec_err = surround_spec(kind, opts)
        if not spec then
            result = spec_err
        else
            result = surround_selection(bufnr, opts, spec)
        end
    end

    if result and result.ok then
        if kind == "function" then
            edit_repeat.set(
                (":TypstSurroundFunction %s<CR>"):format(result.name)
            )
        else
            edit_repeat.set((":TypstSurround %s<CR>"):format(kind))
        end
    end
    result = result
        or {
            ok = false,
            reason = "surround_failed",
            message = "Unable to surround Typst selection",
        }
    notify_result(result, opts)
    return result
end

function M.surround_function(name, opts)
    opts = opts or {}
    opts.name = name
    return M.surround("function", opts)
end

function M.surround_content(opts)
    return M.surround("content", opts)
end

function M.surround_equation(opts)
    return M.surround("equation", opts)
end

function M.surround_figure(opts)
    return M.surround("figure", opts)
end

function M.surround_block(opts)
    return M.surround("block", opts)
end

function M.surround_strong(opts)
    return M.surround("strong", opts)
end

function M.surround_emph(opts)
    return M.surround("emph", opts)
end

return M
