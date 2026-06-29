local config = require("typst.config")
local ftplugin_state = require("typst.core.ftplugin_state")
local lexical = require("typst.syntax.lexical")
local log = require("typst.core.log")
local ts = require("typst.core.treesitter")

local M = {}

-- Typst indentation is deliberately heuristic. It handles common delimiters,
-- math fences, and list continuations, then opts out inside raw/protected
-- regions so Neovim's normal indent rules can leave embedded text alone.

local raw_fence_cache = {}
local treesitter_ignore_cache = {}
local indent_query = nil

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.forget(bufnr)
    if bufnr == nil then
        raw_fence_cache = {}
        treesitter_ignore_cache = {}
        indent_query = nil
        return true
    end
    bufnr = normalize_bufnr(bufnr)
    raw_fence_cache[bufnr] = nil
    treesitter_ignore_cache[bufnr] = nil
    return true
end

function M.reset()
    return M.forget()
end

local function shiftwidth(bufnr)
    local sw = vim.bo[bufnr].shiftwidth
    if sw and sw > 0 then
        return sw
    end

    return vim.bo[bufnr].tabstop > 0 and vim.bo[bufnr].tabstop or 2
end

local function previous_nonblank(lnum)
    for candidate = lnum - 1, 1, -1 do
        if vim.fn.getline(candidate):match("%S") then
            return candidate
        end
    end
end

local function query_available()
    if indent_query ~= nil then
        return indent_query or nil
    end

    local ok, query = pcall(vim.treesitter.query.get, "typst", "indents")
    if not ok or not query then
        indent_query = false
        return nil
    end
    indent_query = query
    return query
end

local function range_before_row(range, row)
    return range.end_row <= row
end

local function range_after_row(range, row)
    return range.start_row >= row
end

local function treesitter_ignore_ranges(bufnr)
    local query = query_available()
    if not query then
        return {}
    end

    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cached = treesitter_ignore_cache[bufnr]
    if cached and cached.changedtick == changedtick then
        return cached.ranges
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    if not ok or not parser then
        treesitter_ignore_cache[bufnr] = {
            changedtick = changedtick,
            ranges = {},
        }
        return {}
    end

    local tree = parser:parse()[1]
    if not tree then
        treesitter_ignore_cache[bufnr] = {
            changedtick = changedtick,
            ranges = {},
        }
        return {}
    end

    local ranges = {}
    for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
        if query.captures[id] == "indent.ignore" then
            local range = ts.range(node)
            if range.start_row < range.end_row then
                ranges[#ranges + 1] = {
                    start_row = range.start_row,
                    end_row = range.end_row,
                }
            end
        end
    end

    table.sort(ranges, function(left, right)
        if left.start_row ~= right.start_row then
            return left.start_row < right.start_row
        end
        return left.end_row < right.end_row
    end)

    treesitter_ignore_cache[bufnr] = {
        changedtick = changedtick,
        ranges = ranges,
    }
    return ranges
end

local function protected_by_treesitter(bufnr, row)
    for _, range in ipairs(treesitter_ignore_ranges(bufnr)) do
        if range_before_row(range, row) then
            -- Ranges are sorted; continue until the row is within or before a
            -- candidate ignore span.
        elseif range_after_row(range, row) then
            break
        elseif row > range.start_row and row < range.end_row then
            return true
        end
    end

    return false
end

local function raw_block_fence(line)
    local _, ticks = lexical.raw_fence_marker(line or "")
    return ticks
end

local function raw_fence_protected_lines(bufnr)
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cached = raw_fence_cache[bufnr]
    if cached and cached.changedtick == changedtick then
        return cached.protected
    end

    local protected = {}
    local active = nil
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for index, line in ipairs(lines) do
        local row = index - 1
        local fence = raw_block_fence(line)
        if active and not fence then
            protected[row] = true
        end
        if fence then
            if active == nil then
                active = fence
            elseif fence == active then
                active = nil
            end
        end
    end

    raw_fence_cache[bufnr] = {
        changedtick = changedtick,
        protected = protected,
    }
    return protected
end

local function protected_by_raw_fence(bufnr, row)
    return raw_fence_protected_lines(bufnr)[row] == true
end

local function strip_source(line)
    return lexical.mask_line(line, {
        strings = "space",
        comments = "space",
        raw = "space",
    })
end

local function delimiter_delta(line)
    local delta = 0
    for char in strip_source(line):gmatch(".") do
        if char == "(" or char == "[" or char == "{" then
            delta = delta + 1
        elseif char == ")" or char == "]" or char == "}" then
            delta = delta - 1
        end
    end
    return delta
end

local function math_fence(line)
    return strip_source(line):match("^%s*%$%s*$") ~= nil
end

local function closes_scope(line)
    local stripped = strip_source(line)
    return stripped:match("^%s*[])}]") ~= nil or math_fence(stripped)
end

local function opens_scope(line)
    return delimiter_delta(line) > 0 or math_fence(line)
end

local function list_marker(line)
    local indent, marker = line:match("^(%s*)([-+*]%s+)")
    if marker then
        return #indent, #marker
    end

    indent, marker = line:match("^(%s*)(%d+%.%s+)")
    if marker then
        return #indent, #marker
    end

    indent, marker = line:match("^(%s*)(/%s+.-:%s*)")
    if marker then
        return #indent, #marker
    end
end

local function list_continuation_indent(prev_line, current_line)
    if
        current_line:match("^%s*[-+*]%s+")
        or current_line:match("^%s*%d+%.%s+")
        or current_line:match("^%s*/%s+")
    then
        return nil
    end

    local indent, marker_width = list_marker(prev_line)
    if indent then
        return indent + marker_width
    end
end

function M.indent(lnum, bufnr)
    bufnr = normalize_bufnr(bufnr)
    lnum = lnum or vim.v.lnum

    if not config.unsafe_get().indent.enabled then
        return -1
    end

    if
        protected_by_treesitter(bufnr, lnum - 1)
        or protected_by_raw_fence(bufnr, lnum - 1)
    then
        -- Returning -1 tells Neovim not to change the indent for regions where
        -- Typst syntax is intentionally opaque to this heuristic.
        return -1
    end

    local prev_lnum = previous_nonblank(lnum)
    if not prev_lnum then
        return 0
    end

    local current_line = vim.fn.getline(lnum)
    local prev_line = vim.fn.getline(prev_lnum)
    local width = shiftwidth(bufnr)
    local indent = vim.fn.indent(prev_lnum)
    local continuation = list_continuation_indent(prev_line, current_line)

    if continuation then
        indent = continuation
    elseif opens_scope(prev_line) then
        indent = indent + width
    end

    if closes_scope(current_line) then
        indent = indent - width
    end

    return math.max(indent, 0)
end

function M.apply(bufnr)
    bufnr = normalize_bufnr(bufnr)

    if not config.unsafe_get().indent.enabled then
        return false
    end

    ftplugin_state.set_buffer_option(
        bufnr,
        "indentexpr",
        "v:lua.typst_nvim_indentexpr(v:lnum)"
    )
    ftplugin_state.set_buffer_option(bufnr, "indentkeys", "0],0),0},0$,!^F,o,O")
    if config.unsafe_get().indent.formatexpr then
        ftplugin_state.set_buffer_option(
            bufnr,
            "formatexpr",
            "v:lua.typst_nvim_formatexpr()"
        )
    end
    log.add("debug", "Typst indentation enabled", { bufnr = bufnr })
    return true
end

return M
