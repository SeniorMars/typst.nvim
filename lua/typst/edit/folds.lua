local config = require("typst.config")
local ftplugin_state = require("typst.core.ftplugin_state")
local log = require("typst.core.log")

local M = {}

-- Fold setup is window-local, but the chosen backend is tracked on the buffer
-- so the foldexpr can cheaply decide whether to delegate to Tree-sitter or use
-- the heading fallback.

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function parser_available(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    return ok and parser ~= nil
end

local function fold_backend(bufnr)
    -- Heading folds are always available and match Typst's `=` section model;
    -- Tree-sitter is an optional refinement when Neovim can evaluate it.
    if
        type(vim.treesitter.foldexpr) == "function" and parser_available(bufnr)
    then
        return "treesitter"
    end
    return "headings"
end

function M.expr(lnum)
    lnum = tonumber(lnum or vim.v.lnum) or 0
    local opts = config.unsafe_get().folds
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    local heading_marker = line:match("^%s*(=+)%s")
    if heading_marker and not opts.headings then
        return "0"
    end

    local marker = opts.headings and heading_marker
    if marker then
        return ">" .. tostring(#marker)
    end

    if
        vim.b.typst_nvim_fold_backend == "treesitter"
        and type(vim.treesitter.foldexpr) == "function"
    then
        return vim.treesitter.foldexpr()
    end
    return "="
end

local function foldtext_context()
    local bufnr = vim.api.nvim_get_current_buf()
    local foldstart = vim.v.foldstart
    local foldend = vim.v.foldend
    local first = vim.api.nvim_buf_get_lines(
        bufnr,
        foldstart - 1,
        foldstart,
        false
    )[1] or ""
    return {
        bufnr = bufnr,
        foldstart = foldstart,
        foldend = foldend,
        line_count = math.max(foldend - foldstart + 1, 0),
        first_line = first,
        text = vim.trim(first:gsub("^%s*(=+)%s*", "%1 ")),
    }
end

function M.foldtext()
    local ctx = foldtext_context()
    local custom = config.unsafe_get().folds.text
    if custom then
        -- Keep custom fold text best-effort. A bad user callback should not
        -- break editing or leave the foldexpr unusable.
        local ok, result = pcall(custom, ctx)
        if ok and result ~= nil then
            return result
        end
        log.add("warn", "Typst foldtext callback failed", {
            bufnr = ctx.bufnr,
            error = result,
        })
    end

    local suffix = ("  [%d line%s]"):format(
        ctx.line_count,
        ctx.line_count == 1 and "" or "s"
    )
    local text = ctx.text ~= "" and ctx.text or vim.trim(ctx.first_line)
    return text .. suffix
end

function M.apply(bufnr, winid)
    bufnr = normalize_bufnr(bufnr)
    winid = winid or vim.api.nvim_get_current_win()

    local opts = config.unsafe_get().folds
    if not opts.enabled then
        return false
    end

    if
        not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return false
    end

    local backend = fold_backend(bufnr)
    vim.b[bufnr].typst_nvim_fold_backend = backend

    ftplugin_state.set_window_option(bufnr, winid, "foldmethod", opts.mode)
    if opts.mode == "expr" then
        ftplugin_state.set_window_option(
            bufnr,
            winid,
            "foldexpr",
            "v:lua.typst_nvim_foldexpr()"
        )
    end
    ftplugin_state.set_window_option(bufnr, winid, "foldlevel", opts.foldlevel)
    if opts.foldtext then
        ftplugin_state.set_window_option(
            bufnr,
            winid,
            "foldtext",
            "v:lua.typst_nvim_foldtext()"
        )
    end
    log.add(
        "debug",
        "Typst folds enabled",
        { bufnr = bufnr, winid = winid, backend = backend, mode = opts.mode }
    )
    return true
end

function M.refresh(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local refreshed = 0
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if M.apply(bufnr, winid) then
            refreshed = refreshed + 1
            pcall(vim.api.nvim_win_call, winid, function()
                vim.cmd("silent! normal! zx")
            end)
        end
    end

    if refreshed == 0 and vim.api.nvim_buf_is_valid(bufnr) then
        M.apply(bufnr)
    end

    return refreshed
end

return M
