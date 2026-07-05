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

local function list_marker(line)
    local indent, marker, body = line:match("^(%s*)([-+])%s+(.*)$")
    if marker then
        return {
            indent = indent,
            marker = marker,
            body = body,
        }
    end
end

local function list_target(kind, line_infos)
    if kind == "bullet" then
        return "-"
    end
    if kind == "numbered" then
        return "+"
    end
    if kind ~= "toggle" then
        error('typst.nvim: list kind must be "toggle", "bullet", or "numbered"')
    end

    local has_bullet = false
    local has_numbered = false
    for _, info in ipairs(line_infos) do
        if info.marker == "-" then
            has_bullet = true
        elseif info.marker == "+" then
            has_numbered = true
        end
    end

    if has_bullet and not has_numbered then
        return "+"
    end
    return "-"
end

local function rewrite_list_line(line, target, remove)
    if line:match("^%s*$") then
        return line
    end

    local parsed = list_marker(line)
    if parsed then
        if remove and parsed.marker == target then
            return parsed.indent .. parsed.body
        end
        return parsed.indent .. target .. " " .. parsed.body
    end

    local indent, body = line:match("^(%s*)(.*)$")
    return indent .. target .. " " .. body
end

function M.toggle(kind, opts)
    opts = opts or {}
    kind = kind or "toggle"
    local bufnr = normalize_bufnr(opts.bufnr)
    local start_row, end_row = selected_rows(bufnr, opts)
    if not start_row or not end_row then
        local result =
            err("position_required", "No Typst cursor position found")
        notify_result(result, opts)
        return result
    end
    start_row = math.max(0, start_row)
    end_row = math.min(vim.api.nvim_buf_line_count(bufnr) - 1, end_row)

    if end_row < start_row then
        local result =
            err("invalid_range", "No Typst lines selected for list toggle")
        notify_result(result, opts)
        return result
    end

    local lines =
        vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local nonblank = {}
    for _, line in ipairs(lines) do
        if not line:match("^%s*$") then
            nonblank[#nonblank + 1] = list_marker(line) or { marker = nil }
        end
    end

    if #nonblank == 0 then
        local result = err(
            "empty_range",
            "No non-empty Typst lines selected for list toggle"
        )
        notify_result(result, opts)
        return result
    end

    local target = list_target(kind, nonblank)
    local remove = kind ~= "toggle"
    if remove then
        for _, info in ipairs(nonblank) do
            if info.marker ~= target then
                remove = false
                break
            end
        end
    end

    local rewritten = {}
    for index, line in ipairs(lines) do
        rewritten[index] = rewrite_list_line(line, target, remove)
    end

    vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, rewritten)
    local result = ok({
        action = "toggle_list",
        message = ("%s Typst %s list"):format(
            remove and "Removed" or "Toggled",
            target == "-" and "bullet" or "numbered"
        ),
        kind = kind,
        target = target == "-" and "bullet" or "numbered",
        start_row = start_row,
        end_row = end_row,
    })
    edit_repeat.set((":TypstToggleList %s<CR>"):format(kind))
    notify_result(result, opts)
    return result
end

function M.toggle_bullet(opts)
    return M.toggle("bullet", opts)
end

function M.toggle_numbered(opts)
    return M.toggle("numbered", opts)
end

return M
