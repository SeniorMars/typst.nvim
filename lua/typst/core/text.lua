local M = {}

function M.split_lines(text)
    local lines = {}
    if not text or text == "" then
        return lines
    end

    for line in text:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end

    return lines
end

function M.scalar_count(text)
    if type(text) ~= "string" then
        return nil
    end

    local ok, count = pcall(vim.str_utfindex, text, "utf-32")
    if ok and type(count) == "number" then
        return count
    end

    return vim.fn.strchars(text)
end

function M.grapheme_count(text)
    if type(text) ~= "string" then
        return nil
    end

    local ok, count = pcall(vim.fn.strchars, text, true)
    if ok and type(count) == "number" then
        return count
    end

    return M.scalar_count(text)
end

function M.codepoints(text)
    if type(text) ~= "string" then
        return nil
    end

    local ok, count = pcall(vim.str_utfindex, text, "utf-32")
    if not ok or type(count) ~= "number" then
        local points = {}
        for _, char in ipairs(vim.fn.split(text, "\\zs")) do
            points[#points + 1] = vim.fn.char2nr(char)
        end
        return points
    end

    local points = {}
    for index = 0, count - 1 do
        local start_ok, start_byte =
            pcall(vim.str_byteindex, text, "utf-32", index, false)
        local end_ok, end_byte =
            pcall(vim.str_byteindex, text, "utf-32", index + 1, false)
        if
            start_ok
            and end_ok
            and type(start_byte) == "number"
            and type(end_byte) == "number"
        then
            points[#points + 1] =
                vim.fn.char2nr(text:sub(start_byte + 1, end_byte))
        end
    end
    return points
end

return M
