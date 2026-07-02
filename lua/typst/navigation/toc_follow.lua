local config = require("typst.config")
local toc_state = require("typst.navigation.toc_state")
local util = require("typst.core.util")
local windows = require("typst.core.windows")

local M = {}

local function cursor_line_for_buf(bufnr)
    if vim.api.nvim_get_current_buf() == bufnr then
        return vim.api.nvim_win_get_cursor(0)[1]
    end

    local winid = windows.for_buffer(bufnr)
    if winid then
        return vim.api.nvim_win_get_cursor(winid)[1]
    end

    return 1
end

local function best_entry_line(entries, path, source_line, headings_only)
    local best_line = nil
    local best_lnum = nil
    local first_after = nil

    for line, entry in ipairs(entries) do
        local item = entry.item
        if
            item
            and util.same_path(item.file, path)
            and (not headings_only or entry.layer == "heading")
        then
            local lnum = item.lnum or 1
            if lnum <= source_line and (not best_lnum or lnum >= best_lnum) then
                best_line = line
                best_lnum = lnum
            elseif not first_after then
                first_after = line
            end
        end
    end

    return best_line or first_after
end

local function current_entry_line(entries, path, source_line)
    return best_entry_line(entries, path, source_line, true)
        or best_entry_line(entries, path, source_line, false)
end

function M.follow(project, bufnr, opts, update_current_marker)
    opts = opts or {}
    local state = toc_state.for_project(project)
    if
        not toc_state.valid_win(state.winid)
        or not toc_state.valid_buf(state.bufnr)
    then
        return nil
    end

    local toc_config = config.unsafe_get().toc
    if
        not opts.force
        and not (toc_config.follow_cursor or toc_config.highlight_current)
    then
        return nil
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not toc_state.valid_buf(bufnr) or toc_state.is_toc_buffer(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        return nil
    end

    path = util.normalize(path)
    local entries = vim.b[state.bufnr].typst_toc_entries or {}
    local line = current_entry_line(entries, path, cursor_line_for_buf(bufnr))
    update_current_marker(state, line)
    return line
end

function M.current_line(project)
    return toc_state.for_project(project).current_line
end

return M
