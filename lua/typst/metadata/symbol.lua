local context = require("typst.package.context")
local open_helper = require("typst.core.open")
local search = require("typst.metadata.symbol_search")
local variants = require("typst.ui.symbol_variants")
local windows = require("typst.core.windows")

local M = {
    search = search.search,
    lookup = search.lookup,
    complete = search.complete,
    variants = variants.list,
}

local symbol_buf = nil
local state_by_buf = {}

local notify = require("typst.core.notify").default

local function as_opts(value)
    if type(value) == "string" then
        return { query = value }
    end

    return value or {}
end

local function valid_buf(bufnr)
    return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function ensure_buffer()
    if valid_buf(symbol_buf) then
        return symbol_buf
    end

    symbol_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[symbol_buf].buftype = "nofile"
    vim.bo[symbol_buf].bufhidden = "hide"
    vim.bo[symbol_buf].swapfile = false
    vim.bo[symbol_buf].filetype = "markdown"
    pcall(vim.api.nvim_buf_set_name, symbol_buf, "typst.nvim symbol info")
    return symbol_buf
end

local function show_buffer(bufnr, opts)
    opts = opts or {}
    if opts.open_winid or opts.jump_winid or opts.target_winid then
        local opened = open_helper.buffer(bufnr, opts)
        return opened and opened.winid or nil
    end

    local winid = windows.for_buffer(bufnr)
    if not winid then
        if opts.command then
            vim.cmd(opts.command)
        else
            vim.cmd("botright split")
        end
        winid = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid, bufnr)
    elseif opts.focus ~= false then
        vim.api.nvim_set_current_win(winid)
    end

    return winid
end

local function set_lines(bufnr, lines)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

local function close_current_window()
    local winid = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
    end
end

local function apply_keymaps(bufnr)
    vim.keymap.set("n", "q", close_current_window, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        desc = "Close Typst symbol info",
    })
end

local function resolve_query(opts)
    opts = as_opts(opts)
    if opts.query then
        return opts.query
    end

    local ctx = context.resolve(opts)
    return ctx and ctx.query or nil
end

local function variant_canonical(variant)
    if type(variant) == "table" then
        return variant.canonical
    end

    return variant
end

local function variant_label(variant)
    if type(variant) ~= "table" then
        return variant
    end

    local label = variant.canonical or ""
    if type(variant.modifiers) == "table" and #variant.modifiers > 0 then
        label = ("%s  [%s]"):format(
            label,
            table.concat(variant.modifiers, ", ")
        )
    end
    if variant.deprecated then
        label = ("%s  deprecated"):format(label)
    end
    return label
end

function M.info(opts)
    opts = as_opts(opts)
    local query = resolve_query(opts)
    local result = query and search.lookup(query) or nil
    if not result then
        notify("No Typst symbol information found", vim.log.levels.WARN)
        return nil
    end

    if opts.open == false then
        return result
    end

    local lines = {
        "# Typst Symbol Info",
        "",
        ("`%s`"):format(result.qualified_name or result.name),
        ("Glyph: %s"):format(result.glyph),
        ("Qualified form: %s"):format(result.qualified_name or result.name),
        ("Typst metadata version: %s"):format(
            result.provider_version or "unknown"
        ),
        ("Category: %s"):format(result.category or result.kind or "symbol"),
    }

    if result.version_mismatch then
        lines[#lines + 1] = ("Requested Typst version: %s"):format(
            result.requested_version or "unknown"
        )
    end

    local rich_variants = result.raw and result.raw.variants or result.variants
    if rich_variants and #rich_variants > 0 then
        local listed = vim.deepcopy(rich_variants)
        table.sort(listed, function(left, right)
            return (variant_canonical(left) or "")
                < (variant_canonical(right) or "")
        end)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## Variants"
        lines[#lines + 1] = ""
        for index, variant in ipairs(listed) do
            if index > 80 then
                lines[#lines + 1] = ("- ... %d more"):format(
                    #listed - index + 1
                )
                break
            end
            lines[#lines + 1] = "- `" .. variant_label(variant) .. "`"
        end
    end

    local bufnr = ensure_buffer()
    state_by_buf[bufnr] = {
        result = result,
    }
    set_lines(bufnr, lines)
    apply_keymaps(bufnr)
    show_buffer(bufnr, opts)
    return result
end

function M.variant_info(opts)
    opts = as_opts(opts)
    local query = resolve_query(opts)
    local result = variants.list(query)
    if opts.open == false then
        return result
    end

    if #result == 0 then
        notify("No Typst symbol variants found", vim.log.levels.WARN)
        return result
    end

    local lines = {
        "# Typst Symbol Variants",
        "",
        ("Query: `%s`"):format(query),
        "",
    }
    for _, variant in ipairs(result) do
        lines[#lines + 1] = "- `" .. variant .. "`"
    end

    local bufnr = ensure_buffer()
    state_by_buf[bufnr] = {
        variants = result,
    }
    set_lines(bufnr, lines)
    apply_keymaps(bufnr)
    show_buffer(bufnr, opts)
    return result
end

function M.reset()
    if valid_buf(symbol_buf) then
        pcall(vim.api.nvim_buf_delete, symbol_buf, { force = true })
    end
    symbol_buf = nil
    state_by_buf = {}
end

return M
