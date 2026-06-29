local config = require("typst.config")
local font_discovery = require("typst.metadata.font_discovery")
local lexical = require("typst.syntax.lexical")

local M = {}

M.namespace = vim.api.nvim_create_namespace("typst.nvim.fonts")

-- Font diagnostics are intentionally a lightweight scan, not a Typst parser.
-- They catch common `font: "..."` and `font: (...)` declarations while staying
-- cheap enough to run from user commands.

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.available(opts)
    return font_discovery.available(opts)
end

local function available_set(opts)
    local set = {}
    for _, name in ipairs(M.available(opts)) do
        set[name:lower()] = name
    end
    return set
end

local function strip_line_comment(line)
    return lexical.strip_line_comment(line)
end

local function paren_delta(text)
    local opens = select(2, text:gsub("%(", ""))
    local closes = select(2, text:gsub("%)", ""))
    return opens - closes
end

local function add_reference(refs, seen, bufnr, lnum, line, start_col, name)
    name = font_discovery.trim(name)
    if not name then
        return
    end

    local key = ("%d:%d:%s"):format(lnum, start_col, name)
    if seen[key] then
        return
    end

    seen[key] = true
    refs[#refs + 1] = {
        bufnr = bufnr,
        lnum = lnum,
        col = start_col,
        end_col = start_col + #name,
        name = name,
        line = line,
    }
end

local function scan_direct_font(refs, seen, bufnr, lnum, line)
    local search = 1
    while true do
        local start_pos, end_pos, name =
            line:find('font%s*:%s*"([^"]+)"', search)
        if not start_pos then
            break
        end

        local matched = line:sub(start_pos, end_pos)
        local quote = matched:find('"', 1, true) or #matched
        add_reference(
            refs,
            seen,
            bufnr,
            lnum,
            line,
            start_pos + quote - 1,
            name
        )
        search = end_pos + 1
    end
end

local function quoted_string_is_coverage(line, quote_pos)
    return line:sub(1, quote_pos - 1):match("covers%s*:%s*$") ~= nil
end

local function scan_font_list_strings(refs, seen, bufnr, lnum, line, offset)
    offset = offset or 0
    local search = 1
    while true do
        local start_pos, end_pos, name = line:find('"([^"]+)"', search)
        if not start_pos then
            break
        end

        if not quoted_string_is_coverage(line, start_pos) then
            add_reference(
                refs,
                seen,
                bufnr,
                lnum,
                line,
                offset + start_pos,
                name
            )
        end
        search = end_pos + 1
    end
end

function M.references(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local refs = {}
    local seen = {}
    local in_font_list = false
    local depth = 0

    for index, original in ipairs(lines) do
        local lnum = index - 1
        local line = strip_line_comment(original)
        scan_direct_font(refs, seen, bufnr, lnum, line)

        local font_pos = line:find("font%s*:%s*%(", 1)
        if font_pos then
            -- Multi-line font lists are tracked with simple parenthesis depth;
            -- this is enough for the diagnostic hint without modeling Typst AST.
            in_font_list = true
            depth = paren_delta(line:sub(font_pos))
            scan_font_list_strings(
                refs,
                seen,
                bufnr,
                lnum,
                line:sub(font_pos),
                font_pos - 1
            )
        elseif in_font_list then
            scan_font_list_strings(refs, seen, bufnr, lnum, line)
            depth = depth + paren_delta(line)
        end

        if in_font_list and depth <= 0 then
            in_font_list = false
            depth = 0
        end
    end

    return refs
end

local function to_qf_item(bufnr, diagnostic)
    return {
        bufnr = bufnr,
        lnum = diagnostic.lnum + 1,
        col = diagnostic.col + 1,
        text = diagnostic.message,
        type = "W",
    }
end

local function set_quickfix(bufnr, diagnostics)
    local items = {}
    for _, diagnostic in ipairs(diagnostics) do
        items[#items + 1] = to_qf_item(bufnr, diagnostic)
    end

    vim.fn.setqflist({}, "r", {
        title = "typst.nvim: font diagnostics",
        items = items,
    })

    return items
end

function M.diagnostics(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local diagnostics_config = config.unsafe_get().diagnostics

    if not diagnostics_config.enabled or not diagnostics_config.fonts then
        vim.diagnostic.reset(M.namespace, bufnr)
        return {
            ok = true,
            provider = "fonts",
            disabled = true,
            diagnostics = 0,
            by_buffer = {
                [bufnr] = {},
            },
        }
    end

    local known = available_set(opts)
    local diagnostics = {}
    for _, ref in ipairs(M.references(bufnr)) do
        if not known[ref.name:lower()] then
            diagnostics[#diagnostics + 1] = {
                lnum = ref.lnum,
                col = ref.col,
                end_col = ref.end_col,
                severity = vim.diagnostic.severity.WARN,
                source = "typst fonts",
                message = ("Font family not reported by typst fonts: %s"):format(
                    ref.name
                ),
            }
        end
    end

    vim.diagnostic.set(M.namespace, bufnr, diagnostics)
    local quickfix = {}
    if opts.open then
        quickfix = set_quickfix(bufnr, diagnostics)
        if #quickfix > 0 then
            vim.cmd("copen")
        end
    end

    return {
        ok = true,
        provider = "fonts",
        diagnostics = #diagnostics,
        fonts = vim.tbl_count(known),
        by_buffer = {
            [bufnr] = diagnostics,
        },
        quickfix = quickfix,
    }
end

return M
