local completion = require("typst.completion")
local config = require("typst.config")
local fonts = require("typst.metadata.fonts")

local M = {}

local notify = require("typst.core.notify").default

local function line_at(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

local function range_on_line(row, start_col, end_col)
    return {
        start_row = row,
        start_col = start_col,
        end_row = row,
        end_col = end_col,
    }
end

local function token_at(bufnr, pos)
    local line = line_at(bufnr, pos[1])
    local cursor = pos[2] + 1
    local start_col = cursor
    while
        start_col > 1
        and line:sub(start_col - 1, start_col - 1):match("[%w_.%-]")
    do
        start_col = start_col - 1
    end

    local end_col = cursor
    while end_col <= #line and line:sub(end_col, end_col):match("[%w_.%-]") do
        end_col = end_col + 1
    end

    if end_col <= start_col then
        return nil
    end

    return {
        text = line:sub(start_col, end_col - 1),
        range = range_on_line(pos[1], start_col - 1, end_col - 1),
    }
end

local function quoted_string_at(bufnr, pos)
    local line = line_at(bufnr, pos[1])
    local cursor = pos[2] + 1
    local search_at = 1
    while true do
        local start_quote, end_quote, text = line:find('"([^"]*)"', search_at)
        if not start_quote then
            return nil
        end

        local content_start = start_quote + 1
        local content_end = end_quote - 1
        if
            cursor >= content_start
            and cursor <= math.max(content_start, content_end)
        then
            return {
                text = text,
                range = range_on_line(pos[1], content_start - 1, content_end),
                start_quote = start_quote,
                end_quote = end_quote,
                line = line,
            }
        end

        search_at = end_quote + 1
    end
end

local function replace_range(bufnr, range, text)
    if not range or not text then
        return nil
    end

    vim.api.nvim_buf_set_text(
        bufnr,
        range.start_row,
        range.start_col,
        range.end_row,
        range.end_col,
        { text }
    )
    return text
end

local function completion_words(context, opts)
    opts = opts or {}
    local items = completion.complete({
        bufnr = opts.bufnr,
        base = opts.base or "",
        context = context,
        limit = opts.limit or 500,
        include_project = false,
    })
    local words = {}
    local seen = {}
    for _, item in ipairs(items) do
        local word = item.word
        if type(word) == "string" and word ~= "" and not seen[word] then
            seen[word] = true
            words[#words + 1] = word
        end
    end
    table.sort(words)
    return words, items
end

local function exact_completion_item(context, word, bufnr)
    if type(word) ~= "string" or word == "" then
        return nil
    end

    local _, items = completion_words(context, {
        bufnr = bufnr,
        base = word,
        limit = 100,
    })
    for _, item in ipairs(items) do
        if item.word == word then
            return item
        end
    end
end

function M.add_color_actions(actions, bufnr, pos)
    local token = token_at(bufnr, pos)
    local item = token and exact_completion_item("color", token.text, bufnr)
    if not item then
        return
    end

    local user_data = item.user_data and item.user_data.typst or {}
    local color = {
        name = token.text,
        kind = user_data.kind or "color",
        provider = user_data.provider or "stdlib",
        range = token.range,
    }

    actions[#actions + 1] = {
        id = "color_preview",
        title = ("Preview color %s"):format(token.text),
        kind = "color",
        context = color,
        run = function(run_opts)
            run_opts = run_opts or {}
            if run_opts.open ~= false then
                notify(
                    ("%s: %s (%s)"):format(
                        color.kind == "color_map" and "Typst color map"
                            or "Typst color",
                        color.name,
                        color.provider
                    )
                )
            end
            return vim.deepcopy(color)
        end,
    }

    actions[#actions + 1] = {
        id = "color_replace",
        title = "Replace color",
        kind = "color",
        context = color,
        run = function(run_opts)
            run_opts = run_opts or {}
            local words = completion_words(
                "color",
                { bufnr = bufnr, base = "", limit = 500 }
            )
            local function apply_color(value)
                if not value then
                    return nil
                end
                return replace_range(bufnr, token.range, value)
            end

            if run_opts.color or run_opts.value then
                return apply_color(run_opts.color or run_opts.value)
            end

            if run_opts.open == false then
                return words
            end

            vim.ui.select(words, { prompt = "Typst color" }, apply_color)
            return words
        end,
    }
end

local function font_context(bufnr, pos)
    local quoted = quoted_string_at(bufnr, pos)
    if not quoted then
        return nil
    end

    local before = quoted.line:sub(1, quoted.start_quote - 1)
    if not before:find("font%s*:", 1) then
        return nil
    end

    return {
        name = quoted.text,
        range = quoted.range,
    }
end

local function font_info(font_name, bufnr)
    local item = exact_completion_item("font_family", font_name, bufnr)
    local available = false
    for _, name in
        ipairs(fonts.available({
            timeout_ms = config.unsafe_get().completion.font_scan_timeout_ms,
        }))
    do
        if name:lower() == font_name:lower() then
            available = true
            break
        end
    end

    return {
        name = font_name,
        available = available or item ~= nil,
        provider = item
                and item.user_data
                and item.user_data.typst
                and item.user_data.typst.provider
            or "unknown",
    }
end

function M.add_font_actions(actions, bufnr, pos)
    local ctx = font_context(bufnr, pos)
    if not ctx then
        return
    end

    actions[#actions + 1] = {
        id = "font_info",
        title = ("Show font info for %s"):format(ctx.name),
        kind = "font",
        context = ctx,
        run = function(run_opts)
            run_opts = run_opts or {}
            local info = font_info(ctx.name, bufnr)
            if run_opts.open ~= false then
                notify(
                    ("%s: %s"):format(
                        info.name,
                        info.available and "available" or "not reported"
                    )
                )
            end
            return info
        end,
    }

    actions[#actions + 1] = {
        id = "font_replace",
        title = "Replace font family",
        kind = "font",
        context = ctx,
        run = function(run_opts)
            run_opts = run_opts or {}
            local words = completion_words(
                "font_family",
                { bufnr = bufnr, base = "", limit = 500 }
            )
            local function apply_font(value)
                if not value then
                    return nil
                end
                return replace_range(bufnr, ctx.range, value)
            end

            if run_opts.font or run_opts.value then
                return apply_font(run_opts.font or run_opts.value)
            end

            if run_opts.open == false then
                return words
            end

            vim.ui.select(words, { prompt = "Typst font family" }, apply_font)
            return words
        end,
    }
end

function M.add_signature_actions(actions, bufnr, pos)
    local signature = completion.signature({ bufnr = bufnr, pos = pos })
    if not signature or not signature.label then
        return
    end

    actions[#actions + 1] = {
        id = "function_signature",
        title = ("Show signature %s"):format(signature.label),
        kind = "signature",
        target = signature.result,
        run = function(run_opts)
            run_opts = run_opts or {}
            if run_opts.open ~= false then
                notify(signature.label)
            end
            return vim.deepcopy(signature)
        end,
    }
end

return M
