local util = require("typst.core.util")

local M = {}

function M.quoted_at(line, col)
    local cursor = col + 1
    local search_at = 1
    while true do
        local start_col, end_col, text = line:find('"([^"]+)"', search_at)
        if not start_col then
            return nil
        end

        if cursor >= start_col and cursor <= end_col then
            return {
                text = text,
                start_col = start_col,
                end_col = end_col,
            }
        end

        search_at = end_col + 1
    end
end

function M.url_at(line, col)
    local cursor = col + 1
    local search_at = 1
    while true do
        local start_col, end_col, url =
            line:find("(https?://[%w%p]+)", search_at)
        if not start_col then
            return nil
        end

        url = url:match('^[^"%]%)]*') or url
        url = url:gsub("[%]>),.;:]+$", "")
        end_col = start_col + #url - 1
        if cursor >= start_col and cursor <= end_col then
            return {
                kind = "url",
                url = url,
                provider = "syntax",
            }
        end

        search_at = end_col + 1
    end
end

local function quoted_named_argument(line, quoted)
    local before = line:sub(1, quoted.start_col - 1)
    return before:match("([%w%-]+)%s*:%s*$")
end

local function call_before_quoted(line, quoted)
    local before = line:sub(1, quoted.start_col - 1)
    local name = nil
    for candidate in before:gmatch("([%w_.%-]+)%s*%(") do
        name = candidate
    end
    return name
end

local function bibliography_style_target(quoted, base)
    local path = util.resolve_path(quoted.text, base)
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    return {
        kind = "path",
        path = path,
        word = quoted.text,
        path_kind = "csl_style",
        provider = "syntax",
    }
end

function M.quoted_target(line, quoted, base)
    if not quoted then
        return nil
    end

    local text = quoted.text
    local before = line:sub(1, quoted.start_col - 1)
    local import_like = before:match("#import%s*$") ~= nil
    local include_like = before:match("#include%s*$") ~= nil
    local call = call_before_quoted(line, quoted)
    if text:match("^https?://") then
        return {
            kind = "url",
            url = text,
            provider = "syntax",
        }
    end

    if text:sub(1, 1) == "@" and import_like then
        return {
            kind = "package",
            spec = text,
            provider = "project",
        }
    end

    local named_argument = quoted_named_argument(line, quoted)
    if
        named_argument == "style" and (call == "bibliography" or call == "cite")
    then
        return bibliography_style_target(quoted, base)
    end
    if named_argument and (call == "bibliography" or call == "cite") then
        return nil
    end

    if
        not import_like
        and not include_like
        and call ~= "include"
        and call ~= "image"
        and call ~= "read"
        and call ~= "bibliography"
    then
        return nil
    end

    return {
        kind = "path",
        path = util.resolve_path(text, base),
        word = text,
        path_kind = include_like and "include"
            or call == "bibliography" and "bibliography"
            or call,
        provider = "syntax",
    }
end

function M.delimited_label_at(line, col)
    local cursor = col + 1
    local search_at = 1
    while true do
        local start_col, end_col, name = line:find("<([^%s<>]+)>", search_at)
        if not start_col then
            return nil
        end

        if cursor >= start_col and cursor <= end_col then
            return name
        end

        search_at = end_col + 1
    end
end

function M.citation_label_at(line, col)
    local cursor = col + 1
    local search_at = 1
    while true do
        local start_col, end_col, name =
            line:find("#?cite%s*%(%s*<([^%s<>]+)>", search_at)
        if not start_col then
            return nil
        end

        local close_col = line:find(")", end_col + 1, true) or end_col
        if cursor >= start_col and cursor <= close_col then
            return name
        end

        search_at = end_col + 1
    end
end

function M.reference_at(line, col)
    local cursor = col + 1
    local search_at = 1
    while true do
        local start_col, end_col, name = line:find("@([%w_.:/%-]+)", search_at)
        if not start_col then
            return nil
        end

        if cursor >= start_col and cursor <= end_col then
            return name
        end

        search_at = end_col + 1
    end
end

function M.word_at(line, col)
    local cursor = col + 1
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

    return line:sub(start_col, end_col - 1)
end

return M
