local calls = require("typst.edit.calls")
local edit_repeat = require("typst.edit.repeat")
local ts = require("typst.core.treesitter")

local M = {}

local call_name = calls.call_name
local content_body_range = calls.content_body_range
local content_node = calls.content_node
local find_call = calls.find_call
local function_name_node = calls.function_name_node
local parent_code_range_for_call = calls.parent_code_range_for_call
local range_text = calls.range_text

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

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

local function edit_function_name(bufnr, call, name)
    local ident = function_name_node(call)
    if not ident then
        return err("no_function_name", "No Typst function name found")
    end

    set_range(bufnr, ts.range(ident), name)
    return ok({
        action = "change_function",
        message = ("Changed Typst function to %s"):format(name),
        name = name,
    })
end

local function strip_content_brackets(bufnr, content)
    local body = content_body_range(content)
    if not body then
        return nil
    end

    return range_text(bufnr, body)
end

function M.change_function(name, opts)
    opts = opts or {}
    if type(name) ~= "string" or name == "" then
        local result =
            err("invalid_name", "Typst function name must be non-empty")
        notify_result(result, opts)
        return result
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local call = find_call(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
        notify_result(result, opts)
        return result
    end

    local result = edit_function_name(bufnr, call, name)
    if result.ok then
        set_repeat((":TypstChangeFunction %s<CR>"):format(name))
    end
    notify_result(result, opts)
    return result
end

function M.unwrap_function(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local call = find_call(bufnr, opts)
    if not call then
        local result =
            err("no_call", "No surrounding Typst function call found")
        notify_result(result, opts)
        return result
    end

    local content = content_node(call)
    if not content then
        local result = err(
            "no_content_argument",
            "The surrounding Typst function has no trailing content block"
        )
        notify_result(result, opts)
        return result
    end

    local body = strip_content_brackets(bufnr, content)
    if body == nil then
        local result = err(
            "invalid_content",
            "The surrounding Typst function content block cannot be unwrapped"
        )
        notify_result(result, opts)
        return result
    end

    local name = call_name(bufnr, call)
    set_range(
        bufnr,
        parent_code_range_for_call(bufnr, call) or ts.range(call),
        body
    )
    local result = ok({
        action = "unwrap_function",
        message = "Unwrapped Typst function call",
        name = name,
    })
    set_repeat(":TypstUnwrapFunction<CR>")
    notify_result(result, opts)
    return result
end

return M
