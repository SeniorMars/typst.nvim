local config = require("typst.config")
local toc_entries = require("typst.navigation.toc_entries")
local toc_follow = require("typst.navigation.toc_follow")
local toc_state = require("typst.navigation.toc_state")
local util = require("typst.core.util")

local M = {}

local namespace = vim.api.nvim_create_namespace("typst.nvim.toc")
local highlights_defined = false

local function ensure_highlights()
    if highlights_defined then
        return
    end

    pcall(vim.api.nvim_set_hl, 0, "TypstTocCurrent", {
        default = true,
        link = "CursorLine",
    })
    highlights_defined = true
end

function M.ensure_buffer(project)
    local state = toc_state.for_project(project)
    if toc_state.valid_buf(state.bufnr) then
        return state.bufnr, state
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    state.bufnr = bufnr
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].filetype = "typsttoc"
    vim.b[bufnr].typst_toc = true
    vim.b[bufnr].typst_toc_project = toc_state.project_key(project)
    pcall(vim.api.nvim_buf_set_name, bufnr, toc_state.title(project))
    return bufnr, state
end

function M.render(project, bufnr, entries, state, opts)
    local lines = {}
    local items = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = toc_entries.window_text(project, state, entry)
        items[#items + 1] = entry.item
    end
    if #lines == 0 then
        lines[1] = "(no TOC entries)"
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    vim.b[bufnr].typst_toc = true
    vim.b[bufnr].typst_toc_items = items
    vim.b[bufnr].typst_toc_entries = entries
    vim.b[bufnr].typst_toc_opts = opts
    vim.b[bufnr].typst_toc_filter = toc_entries.normalized_filter(state.filter)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

local function entry_key_at(state, line)
    if not line or not toc_state.valid_buf(state.bufnr) then
        return nil
    end

    local entries = vim.b[state.bufnr].typst_toc_entries or {}
    local entry = entries[line]
    return entry and entry.key or nil
end

function M.update_current_marker(state, line, opts)
    opts = opts or {}
    if not toc_state.valid_buf(state.bufnr) then
        return false
    end

    vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
    if
        not line
        or line < 1
        or line > vim.api.nvim_buf_line_count(state.bufnr)
    then
        state.current_line = nil
        state.current_key = nil
        return false
    end

    state.current_line = line
    state.current_key = entry_key_at(state, line)

    local toc_config = config.unsafe_get().toc
    if toc_config.highlight_current then
        ensure_highlights()
        vim.api.nvim_buf_set_extmark(state.bufnr, namespace, line - 1, 0, {
            line_hl_group = "TypstTocCurrent",
        })
    end

    if
        toc_config.follow_cursor
        and opts.move_cursor ~= false
        and toc_state.valid_win(state.winid)
    then
        pcall(vim.api.nvim_win_set_cursor, state.winid, { line, 0 })
    end

    return true
end

local function restore_current_marker(state, entries)
    if not state.current_key then
        return M.update_current_marker(
            state,
            state.current_line,
            { move_cursor = false }
        )
    end

    for line, entry in ipairs(entries) do
        if entry.key == state.current_key then
            return M.update_current_marker(state, line, { move_cursor = false })
        end
    end

    return M.update_current_marker(state, nil, { move_cursor = false })
end

local function desired_toc_size(opts)
    local toc_config = config.unsafe_get().toc
    return {
        position = opts.position or toc_config.position,
        width = opts.width or toc_config.width,
        height = opts.height or toc_config.height,
    }
end

local function open_split(project, bufnr, opts)
    local state = toc_state.for_project(project)
    local size = desired_toc_size(opts)
    if toc_state.valid_win(state.winid) then
        vim.api.nvim_set_current_win(state.winid)
        vim.api.nvim_win_set_buf(state.winid, bufnr)
    else
        state.origin_win = vim.api.nvim_get_current_win()
        if size.position == "left" then
            vim.cmd(("topleft vertical %dnew"):format(size.width))
        elseif size.position == "top" then
            vim.cmd(("topleft %dnew"):format(size.height))
        elseif size.position == "bottom" then
            vim.cmd(("botright %dnew"):format(size.height))
        else
            vim.cmd(("botright vertical %dnew"):format(size.width))
        end
        state.winid = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.winid, bufnr)
    end

    if size.position == "left" or size.position == "right" then
        pcall(vim.api.nvim_win_set_width, state.winid, size.width)
    else
        pcall(vim.api.nvim_win_set_height, state.winid, size.height)
    end
    vim.wo[state.winid].wrap = false
    vim.wo[state.winid].foldenable = false
    return state.winid
end

function M.open(project, entries, opts)
    local bufnr = M.ensure_buffer(project)
    local cursor = { 1, 0 }
    local cursor_key = nil
    local state = toc_state.for_project(project)
    if toc_state.valid_win(state.winid) then
        cursor = vim.api.nvim_win_get_cursor(state.winid)
        local current_entries = vim.b[bufnr].typst_toc_entries or {}
        local current_entry = current_entries[cursor[1]]
        cursor_key = current_entry and current_entry.key
    end

    M.render(project, bufnr, entries, state, opts)
    restore_current_marker(state, entries)
    local winid = open_split(project, bufnr, opts)
    local max_line = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
    local target_line = math.min(cursor[1], max_line)
    if cursor_key then
        for line, entry in ipairs(entries) do
            if entry.key == cursor_key then
                target_line = line
                break
            end
        end
    end
    pcall(vim.api.nvim_win_set_cursor, winid, { target_line, cursor[2] })
    return winid, bufnr
end

local function target_window(state, toc_winid)
    if
        toc_state.valid_win(state.origin_win)
        and state.origin_win ~= toc_winid
    then
        local bufnr = vim.api.nvim_win_get_buf(state.origin_win)
        if
            not toc_state.is_toc_buffer(bufnr)
            and vim.bo[bufnr].buftype ~= "quickfix"
        then
            return state.origin_win
        end
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if winid ~= toc_winid then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            if
                not toc_state.is_toc_buffer(bufnr)
                and vim.bo[bufnr].buftype ~= "quickfix"
            then
                return winid
            end
        end
    end
end

function M.current_entry()
    local bufnr = vim.api.nvim_get_current_buf()
    local entries = vim.b[bufnr].typst_toc_entries or {}
    return entries[math.max(vim.fn.line("."), 1)]
end

function M.open_entry(project, opts)
    opts = opts or {}
    local entry = M.current_entry()
    local item = entry and entry.item
    if not item or not item.file then
        return nil, false
    end

    local state = toc_state.for_project(project)
    local toc_winid = vim.api.nvim_get_current_win()
    local winid = target_window(state, toc_winid)
    if winid then
        vim.api.nvim_set_current_win(winid)
    else
        vim.cmd("belowright split")
    end

    util.edit_existing_or_path(item.file)
    pcall(
        vim.api.nvim_win_set_cursor,
        0,
        { item.lnum or 1, math.max((item.col or 1) - 1, 0) }
    )
    pcall(vim.cmd, "normal! zv")

    if opts.preview and toc_state.valid_win(toc_winid) then
        vim.api.nvim_set_current_win(toc_winid)
    end

    return item, not opts.preview and config.unsafe_get().toc.auto_close
end

function M.follow(project, bufnr, opts)
    return toc_follow.follow(project, bufnr, opts, M.update_current_marker)
end

M.current_line = toc_follow.current_line

return M
