local config = require("typst.config")

local M = {}

local function is_blank(line)
    return line:match("^%s*$") ~= nil
end

local function is_raw_fence(line)
    return line:match("^%s*```") ~= nil
end

local function is_plain_prose_paragraph(lines)
    if #lines == 0 then
        return false
    end

    for index, line in ipairs(lines) do
        if line:match("^%s") then
            return false
        end
        if line:match("^%s*[=#]") or line:match("^%s*//") then
            return false
        end
        if line:match("^%s*[%-%+]%s+") or line:match("^%s*%d+[%.%)]%s+") then
            return false
        end
        if
            line:find("```", 1, true)
            or line:find("`", 1, true)
            or line:find("$", 1, true)
        then
            return false
        end
        if line:find("#", 1, true) then
            return false
        end
        if index == 1 and (line:match("^%s*%[") or line:match("^%s*%]")) then
            return false
        end
    end

    return true
end

local function display_width(text)
    return vim.fn.strdisplaywidth(text)
end

local function wrap_text(text, width)
    width = math.max(tonumber(width) or 80, 1)
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return { "" }
    end

    local words = vim.split(text, "%s+", { trimempty = true })
    local wrapped = {}
    local current = ""

    for _, word in ipairs(words) do
        local candidate = current == "" and word or (current .. " " .. word)
        if current ~= "" and display_width(candidate) > width then
            wrapped[#wrapped + 1] = current
            current = word
        else
            current = candidate
        end
    end

    if current ~= "" then
        wrapped[#wrapped + 1] = current
    end

    return wrapped
end

function M.format_text(lines, width)
    local out = {}
    local index = 1
    local in_raw_block = false

    while index <= #lines do
        local line = lines[index]
        if is_raw_fence(line) then
            in_raw_block = not in_raw_block
            out[#out + 1] = line
            index = index + 1
        elseif in_raw_block or is_blank(line) then
            out[#out + 1] = line
            index = index + 1
        else
            local paragraph = {}
            while
                index <= #lines
                and not is_blank(lines[index])
                and not is_raw_fence(lines[index])
            do
                paragraph[#paragraph + 1] = lines[index]
                index = index + 1
            end

            if is_plain_prose_paragraph(paragraph) then
                local wrapped = wrap_text(table.concat(paragraph, " "), width)
                vim.list_extend(out, wrapped)
            else
                vim.list_extend(out, paragraph)
            end
        end
    end

    return out
end

function M.run(bufnr, opts)
    opts = opts or {}
    local format_config = config.unsafe_get().format
    local width = opts.width or opts.prose_width or format_config.prose_width
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local formatted = M.format_text(lines, width)
    local text = table.concat(formatted, "\n")
    if vim.bo[bufnr].endofline then
        text = text .. "\n"
    end

    return {
        ok = true,
        provider = "prose",
        text = text,
        width = width,
    }
end

return M
