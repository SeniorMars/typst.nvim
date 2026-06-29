local config = require("typst.config")
local ftplugin_state = require("typst.core.ftplugin_state")
local lexical = require("typst.syntax.lexical")

local M = {}

local registered = {}

local builtins = {
    {
        lhs = ";a",
        rhs = "alpha",
        modes = { "math" },
        priority = 10,
        description = "Typst alpha symbol",
    },
    {
        lhs = ";b",
        rhs = "beta",
        modes = { "math" },
        priority = 10,
        description = "Typst beta symbol",
    },
    {
        lhs = ";g",
        rhs = "gamma",
        modes = { "math" },
        priority = 10,
        description = "Typst gamma symbol",
    },
    {
        lhs = ";d",
        rhs = "delta",
        modes = { "math" },
        priority = 10,
        description = "Typst delta symbol",
    },
    {
        lhs = ";p",
        rhs = "pi",
        modes = { "math" },
        priority = 10,
        description = "Typst pi symbol",
    },
    {
        lhs = ";s",
        rhs = "sum",
        modes = { "math" },
        priority = 10,
        description = "Typst sum symbol",
    },
    {
        lhs = ";i",
        rhs = "integral",
        modes = { "math" },
        priority = 10,
        description = "Typst integral symbol",
    },
    {
        lhs = ";f",
        rhs = "frac(, )<Left><Left><Left>",
        modes = { "math" },
        priority = 20,
        description = "Typst fraction call",
    },
    {
        lhs = ";r",
        rhs = "sqrt()<Left>",
        modes = { "math" },
        priority = 20,
        description = "Typst square root call",
    },
    {
        lhs = ";m",
        rhs = "$  $<Left><Left>",
        modes = { "markup" },
        priority = 20,
        description = "Typst inline equation pair",
    },
}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function copy_entry(entry)
    local copy = {}
    for key, value in pairs(entry or {}) do
        copy[key] = value
    end
    return copy
end

local function validate_entry(entry)
    if type(entry) ~= "table" then
        error("typst.nvim: imap entry must be a table")
    end
    if type(entry.lhs) ~= "string" or entry.lhs == "" then
        error("typst.nvim: imap lhs must be a non-empty string")
    end
    if type(entry.rhs) ~= "string" and type(entry.rhs) ~= "function" then
        error("typst.nvim: imap rhs must be a string or function")
    end
    if entry.modes ~= nil and type(entry.modes) ~= "table" then
        error("typst.nvim: imap modes must be a list or nil")
    end
    if entry.condition ~= nil and type(entry.condition) ~= "function" then
        error("typst.nvim: imap condition must be a function or nil")
    end
end

local function entry_id(entry)
    return entry.id
        or ("%s:%s"):format(entry.lhs, entry.description or tostring(entry.rhs))
end

local function cursor_context(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
    local lexical_context = lexical.context_at(lines, row, col)
    local line = lines[#lines] or ""
    local before = line:sub(1, col)
    local masked = lexical.mask_line(before, {
        strings = "space",
        raw = "space",
        comments = "space",
    })
    local dollars = 0
    for index = 1, #masked do
        if
            masked:sub(index, index) == "$"
            and not lexical.is_escaped(masked, index)
        then
            dollars = dollars + 1
        end
    end
    local mode = dollars % 2 == 1 and "math" or "markup"
    if
        lexical_context == "raw"
        or lexical_context == "comment"
        or lexical_context == "string"
    then
        mode = lexical_context
    end
    return {
        bufnr = bufnr,
        row = row,
        col = col,
        mode = mode,
        lexical = lexical_context,
    }
end

local function mode_matches(entry, ctx)
    if not entry.modes then
        return true
    end
    for _, mode in ipairs(entry.modes) do
        if mode == ctx.mode then
            return true
        end
    end
    return false
end

local function all_entries()
    local opts = config.unsafe_get().imaps
    local entries = {}
    if opts.builtins then
        for _, entry in ipairs(builtins) do
            entries[#entries + 1] = entry
        end
    end
    for _, entry in ipairs(opts.mappings or {}) do
        entries[#entries + 1] = entry
    end
    for _, entry in pairs(registered) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(left, right)
        if (left.priority or 0) ~= (right.priority or 0) then
            return (left.priority or 0) > (right.priority or 0)
        end
        return (left.lhs or "") < (right.lhs or "")
    end)
    return entries
end

local function matching_entries(bufnr, lhs)
    local ctx = cursor_context(bufnr)
    local matches = {}
    for _, entry in ipairs(all_entries()) do
        if (lhs == nil or entry.lhs == lhs) and mode_matches(entry, ctx) then
            local condition_ok = true
            if entry.condition then
                local ok, result = pcall(entry.condition, ctx)
                condition_ok = ok and result == true
            end
            if condition_ok then
                matches[#matches + 1] = entry
            end
        end
    end
    return matches, ctx
end

function M.register(entry)
    validate_entry(entry)
    local copy = copy_entry(entry)
    local id = entry_id(copy)
    copy.id = id
    registered[id] = copy
    return id
end

function M.unregister(id)
    if registered[id] then
        registered[id] = nil
        return true
    end

    local removed = false
    for entry_id_value, entry in pairs(registered) do
        if entry.lhs == id then
            registered[entry_id_value] = nil
            removed = true
        end
    end
    return removed
end

function M.list()
    local entries = {}
    for _, entry in ipairs(all_entries()) do
        entries[#entries + 1] = copy_entry(entry)
    end
    return entries
end

function M.active(bufnr)
    if not config.unsafe_get().imaps.enabled then
        return {}
    end
    local matches = matching_entries(bufnr)
    local active = {}
    for _, entry in ipairs(matches) do
        active[#active + 1] = copy_entry(entry)
    end
    return active
end

function M.expand(lhs, bufnr)
    bufnr = normalize_bufnr(bufnr)
    local matches, ctx = matching_entries(bufnr, lhs)
    local entry = matches[1]
    if not entry then
        return lhs
    end
    if type(entry.rhs) == "function" then
        local ok, result = pcall(entry.rhs, ctx)
        return ok and result or lhs
    end
    return entry.rhs
end

function M.apply(bufnr)
    bufnr = normalize_bufnr(bufnr)
    if not config.unsafe_get().imaps.enabled then
        return false
    end

    local seen = {}
    for _, entry in ipairs(all_entries()) do
        if not seen[entry.lhs] then
            seen[entry.lhs] = true
            local lhs = entry.lhs
            ftplugin_state.set_buffer_mapping(bufnr, "i", entry.lhs, function()
                return M.expand(lhs, bufnr)
            end, {
                expr = true,
                replace_keycodes = true,
                silent = true,
                desc = entry.description or "Typst insert mapping",
            })
        end
    end
    return true
end

function M.lines(bufnr)
    local entries = M.list()
    local active_lookup = {}
    for _, entry in ipairs(M.active(bufnr)) do
        active_lookup[entry_id(entry)] = true
    end

    local lines = { "typst.nvim insert mappings" }
    if not config.unsafe_get().imaps.enabled then
        lines[#lines + 1] = "  disabled"
    end
    for _, entry in ipairs(entries) do
        local modes = entry.modes and table.concat(entry.modes, ",") or "any"
        local state = active_lookup[entry_id(entry)] and "active" or "inactive"
        lines[#lines + 1] = ("  %-8s %-8s %-7s %s"):format(
            entry.lhs,
            modes,
            state,
            entry.description or ""
        )
    end
    return lines
end

return M
