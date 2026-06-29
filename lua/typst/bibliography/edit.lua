local M = {}
local indent_cache = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.forget(bufnr)
    if bufnr == nil then
        indent_cache = {}
        return true
    end
    indent_cache[normalize_bufnr(bufnr)] = nil
    return true
end

function M.reset()
    return M.forget()
end

local function line_at(bufnr, lnum)
    return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
end

local function shiftwidth(bufnr)
    local sw = vim.bo[bufnr].shiftwidth
    if sw and sw > 0 then
        return sw
    end
    return vim.bo[bufnr].tabstop > 0 and vim.bo[bufnr].tabstop or 2
end

local function file_kind(bufnr)
    local ft = vim.bo[bufnr].filetype
    if ft == "bib" or ft == "bibtex" then
        return "bibtex"
    end
    if ft == "yaml" or ft == "yml" or ft == "hayagriva" then
        return "hayagriva"
    end

    local ext =
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":e"):lower()
    if ext == "bib" then
        return "bibtex"
    end
    if ext == "yml" or ext == "yaml" then
        return "hayagriva"
    end
end

local function indent_state(bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cached = indent_cache[bufnr]
    if cached and cached.changedtick == changedtick then
        return cached
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local bibtex_inside = {}
    local hayagriva_after_key = {}
    local inside_entry = false

    for lnum, line in ipairs(lines) do
        if line:match("^%s*[%}%)]%s*,?%s*$") then
            inside_entry = false
            bibtex_inside[lnum] = false
        elseif line:match("^%s*@[%a]+%s*[%(%{]") then
            bibtex_inside[lnum] = false
            inside_entry = true
        else
            bibtex_inside[lnum] = inside_entry
        end

        if line:match("^[%w_.:-]+:%s*$") then
            hayagriva_after_key[lnum + 1] = true
        end
    end

    cached = {
        changedtick = changedtick,
        lines = lines,
        bibtex_inside = bibtex_inside,
        hayagriva_after_key = hayagriva_after_key,
    }
    indent_cache[bufnr] = cached
    return cached
end

function M.foldexpr(lnum, bufnr)
    bufnr = normalize_bufnr(bufnr)
    lnum = tonumber(lnum or vim.v.lnum) or 1
    local kind = file_kind(bufnr)
    local line = line_at(bufnr, lnum)

    if kind == "bibtex" then
        if line:match("^%s*@[%a]+%s*[%(%{]") then
            return ">1"
        end
        if line:match("^%s*[%}%)]%s*,?%s*$") then
            return "<1"
        end
        return "="
    end

    if kind == "hayagriva" then
        if line:match("^[%w_.:-]+:%s*$") then
            return ">1"
        end
        if line:match("^%S") then
            return "0"
        end
        return "="
    end

    return "0"
end

function M.indentexpr(lnum, bufnr)
    bufnr = normalize_bufnr(bufnr)
    lnum = tonumber(lnum or vim.v.lnum) or 1
    local kind = file_kind(bufnr)
    local state = indent_state(bufnr)
    local line = state.lines[lnum] or ""
    local width = shiftwidth(bufnr)

    if kind == "bibtex" then
        if line:match("^%s*[%}%)]") then
            return 0
        end
        if line:match("^%s*@[%a]+%s*[%(%{]") then
            return 0
        end
        if state.bibtex_inside[lnum] then
            return width
        end
        return 0
    end

    if kind == "hayagriva" then
        if state.hayagriva_after_key[lnum] then
            return width
        end
        if line:match("^%S") then
            return 0
        end
    end

    return -1
end

return M
