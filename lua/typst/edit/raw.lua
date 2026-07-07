local calls = require("typst.edit.calls")
local cursor = require("typst.edit.cursor")
local edit_repeat = require("typst.edit.repeat")
local ts = require("typst.core.treesitter")

local M = {}

local first_child = calls.first_child
local node_text = calls.node_text

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

local function nonempty(text)
    return type(text) == "string" and text:find("%S") ~= nil
end

local function find_raw(bufnr, opts)
    opts = opts or {}
    return ts.find_containing(bufnr, "raw", cursor_pos(bufnr, opts))
end

local function raw_child_text(bufnr, node, node_type)
    local child = first_child(node, node_type)
    return child and node_text(bufnr, child) or nil
end

local function raw_is_inline(bufnr, node)
    local delimiter = raw_child_text(bufnr, node, "raw_delimiter") or ""
    return #delimiter < 3
end

local function strip_one_leading_newline(text)
    text = text or ""
    if text:sub(1, 2) == "\r\n" then
        return text:sub(3)
    end
    if text:sub(1, 1) == "\n" then
        return text:sub(2)
    end
    return text
end

local function strip_one_trailing_newline(text)
    text = text or ""
    if text:sub(-2) == "\r\n" then
        return text:sub(1, -3)
    end
    if text:sub(-1) == "\n" then
        return text:sub(1, -2)
    end
    return text
end

local function raw_body(bufnr, node)
    local body = raw_child_text(bufnr, node, "raw_content")
        or raw_child_text(bufnr, node, "blob")
        or ""
    if not raw_is_inline(bufnr, node) then
        return strip_one_trailing_newline(strip_one_leading_newline(body))
    end
    return body
end

local function raw_body_lines(body)
    if body == "" then
        return {}
    end
    return vim.split(body, "\n", { plain = true })
end

local function raw_block_fence(body)
    local longest = 2
    for run in (body or ""):gmatch("`+") do
        longest = math.max(longest, #run)
    end
    return string.rep("`", math.max(3, longest + 1))
end

local function convert_inline_raw(bufnr, node)
    local body = raw_body(bufnr, node)
    local range = ts.range(node)
    local start_line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.start_row,
        range.start_row + 1,
        false
    )[1] or ""
    local end_line = vim.api.nvim_buf_get_lines(
        bufnr,
        range.end_row,
        range.end_row + 1,
        false
    )[1] or ""
    local before = start_line:sub(1, range.start_col)
    local after = end_line:sub(range.end_col + 1)
    local indent = before:match("^%s*") or ""
    local fence = raw_block_fence(body)
    local lines = {}

    if nonempty(before) then
        lines[#lines + 1] = before:gsub("%s+$", "")
    end

    lines[#lines + 1] = indent .. fence
    for _, raw_line in ipairs(raw_body_lines(body)) do
        lines[#lines + 1] = raw_line
    end
    lines[#lines + 1] = indent .. fence

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
        action = "raw_block",
        message = "Converted Typst raw text to block form",
        style = "block",
    })
end

local function convert_block_raw(bufnr, node)
    local body = raw_body(bufnr, node)
    local language = raw_child_text(bufnr, node, "raw_language")
    if body:find("\n", 1, true) then
        return err(
            "multiline_raw",
            "Multi-line Typst raw blocks cannot be converted to inline form without changing content"
        )
    end
    if body:find("`", 1, true) then
        return err(
            "unsafe_raw",
            "Typst raw blocks containing backticks cannot be converted to inline form"
        )
    end

    set_range(bufnr, ts.range(node), ("`%s`"):format(body))
    return ok({
        action = "raw_inline",
        message = "Converted Typst raw block to inline form",
        style = "inline",
        language = language,
    })
end

function M.convert_raw(style, opts)
    opts = opts or {}
    style = style or "toggle"
    if style ~= "toggle" and style ~= "inline" and style ~= "block" then
        error('typst.nvim: raw style must be "toggle", "inline", or "block"')
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local node = find_raw(bufnr, opts)
    if not node then
        local result = err("no_raw", "No surrounding Typst raw text found")
        notify_result(result, opts)
        return result
    end

    local is_inline = raw_is_inline(bufnr, node)
    local target = style
    if target == "toggle" then
        target = is_inline and "block" or "inline"
    end

    if target == "inline" and is_inline then
        local result = err(
            "already_inline",
            "The surrounding Typst raw text is already inline"
        )
        notify_result(result, opts)
        return result
    end
    if target == "block" and not is_inline then
        local result = err(
            "already_block",
            "The surrounding Typst raw text is already a block"
        )
        notify_result(result, opts)
        return result
    end

    local result = target == "inline" and convert_block_raw(bufnr, node)
        or convert_inline_raw(bufnr, node)
    if result.ok then
        set_repeat((":TypstConvertRaw %s<CR>"):format(style))
    end
    notify_result(result, opts)
    return result
end

return M
