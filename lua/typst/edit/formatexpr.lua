local lexical = require("typst.syntax.lexical")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function wrap_words(words, width, prefix)
    local lines = {}
    local line = prefix
    local content_width = math.max(width - #prefix, 20)

    for _, word in ipairs(words) do
        if #word > 0 then
            local current = line == prefix and "" or line:sub(#prefix + 1)
            if current ~= "" and #current + 1 + #word > content_width then
                lines[#lines + 1] = line
                line = prefix .. word
            elseif current == "" then
                line = prefix .. word
            else
                line = line .. " " .. word
            end
        end
    end

    if line ~= prefix or #lines == 0 then
        lines[#lines + 1] = line
    end
    return lines
end

local function words_from(lines)
    local words = {}
    for _, line in ipairs(lines) do
        for word in vim.trim(line):gmatch("%S+") do
            words[#words + 1] = word
        end
    end
    return words
end

local function raw_context(bufnr, row)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
    return lexical.context_at(lines, row, 1) == "raw"
end

local function unsafe_prose_line(bufnr, row, line)
    if raw_context(bufnr, row) then
        return true
    end

    local code = lexical.mask_line(line, {
        strings = "space",
        raw = "space",
        comments = "space",
    })
    return code:match("^%s*$")
        or code:match("^%s*=")
        or code:match("^%s*#")
        or code:match("^%s*[%-%+%*]%s+")
        or code:match("^%s*%d+%.%s+")
        or code:match("^%s*/%s+.-:")
        or code:match("^%s*%$%s*$")
        or code:match("^%s*`")
        or code:find("[%[%]{}()]", 1) ~= nil
end

local function classify_comments(lines)
    local prefix = nil
    local bodies = {}
    for _, line in ipairs(lines) do
        local indent, marker, space, body =
            line:match("^(%s*)(//[/!]*)(%s*)(.*)$")
        if not indent then
            return nil
        end
        local candidate = indent .. marker .. (space ~= "" and " " or "")
        if prefix and prefix ~= candidate then
            return nil
        end
        prefix = candidate
        bodies[#bodies + 1] = body
    end
    return prefix, bodies
end

local function classify_prose(bufnr, start_lnum, lines)
    local indent = nil
    local bodies = {}
    for index, line in ipairs(lines) do
        if unsafe_prose_line(bufnr, start_lnum + index - 2, line) then
            return nil
        end
        local candidate, body = line:match("^(%s*)(.*)$")
        if indent and indent ~= candidate then
            return nil
        end
        indent = indent or candidate
        bodies[#bodies + 1] = body
    end
    return indent or "", bodies
end

function M.format_range(bufnr, start_lnum, count)
    bufnr = normalize_bufnr(bufnr)
    start_lnum = tonumber(start_lnum or vim.v.lnum) or 1
    count = tonumber(count or vim.v.count) or 1
    local stop_lnum = math.min(
        start_lnum + math.max(count, 1) - 1,
        vim.api.nvim_buf_line_count(bufnr)
    )
    local lines =
        vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, stop_lnum, false)
    if #lines == 0 then
        return false
    end

    local width = vim.bo[bufnr].textwidth
    if width == nil or width <= 0 then
        width = 80
    end

    local prefix, bodies = classify_comments(lines)
    if not prefix then
        prefix, bodies = classify_prose(bufnr, start_lnum, lines)
    end
    if not prefix or not bodies then
        return false
    end

    local new_lines = wrap_words(words_from(bodies), width, prefix)
    local ok = pcall(
        vim.api.nvim_buf_set_lines,
        bufnr,
        start_lnum - 1,
        stop_lnum,
        false,
        new_lines
    )
    return ok
end

function M.formatexpr(lnum, count, bufnr)
    return M.format_range(bufnr, lnum, count) and 0 or 1
end

return M
