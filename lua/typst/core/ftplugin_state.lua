local M = {}

local buffer_state = {}
local window_state = {}

-- Reversible buffer/window mutations made by the ftplugin.
--
-- Restore only if the value still matches what typst.nvim installed. That lets
-- user mappings, modelines, or other plugins take over after attach without
-- being overwritten during detach.
local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function expand_modes(mode)
    if type(mode) == "table" then
        return mode
    end
    return { mode }
end

local function expanded_lhs(lhs)
    if type(lhs) ~= "string" then
        return lhs
    end

    return lhs:gsub("<[Ll]ocal[Ll]eader>", vim.g.maplocalleader or "\\")
        :gsub("<[Ll]eader>", vim.g.mapleader or "\\")
end

local function state_for(bufnr)
    bufnr = normalize_bufnr(bufnr)
    buffer_state[bufnr] = buffer_state[bufnr]
        or {
            options = {},
            mappings = {},
        }
    return buffer_state[bufnr]
end

local function current_buffer_mapping(bufnr, mode, lhs)
    local expanded = expanded_lhs(lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
        if mapping.lhs == lhs or mapping.lhs == expanded then
            return mapping
        end
    end
end

local function mapping_identity(mapping)
    if not mapping then
        return nil
    end

    return {
        lhs = mapping.lhs,
        rhs = mapping.rhs,
        callback = mapping.callback,
        expr = mapping.expr == 1,
        noremap = mapping.noremap == 1,
        nowait = mapping.nowait == 1,
        replace_keycodes = mapping.replace_keycodes == 1,
        script = mapping.script == 1,
        silent = mapping.silent == 1,
        desc = mapping.desc,
    }
end

local function mapping_flag(mapping, name)
    return mapping[name] == true or mapping[name] == 1
end

local function mapping_matches(mapping, identity)
    if not mapping or not identity then
        return false
    end

    local current = mapping_identity(mapping)
    return current.lhs == identity.lhs
        and current.rhs == identity.rhs
        and current.callback == identity.callback
        and current.expr == identity.expr
        and current.noremap == identity.noremap
        and current.nowait == identity.nowait
        and current.replace_keycodes == identity.replace_keycodes
        and current.script == identity.script
        and current.silent == identity.silent
        and current.desc == identity.desc
end

local function mapping_opts(bufnr, mapping)
    return {
        buffer = bufnr,
        expr = mapping_flag(mapping, "expr"),
        remap = not mapping_flag(mapping, "noremap"),
        nowait = mapping_flag(mapping, "nowait"),
        replace_keycodes = mapping_flag(mapping, "replace_keycodes"),
        script = mapping_flag(mapping, "script"),
        silent = mapping_flag(mapping, "silent"),
        desc = mapping.desc,
    }
end

local function restore_mapping(bufnr, record)
    local current = record.installed
            and current_buffer_mapping(bufnr, record.mode, record.installed.lhs)
        or nil
    current = current or current_buffer_mapping(bufnr, record.mode, record.lhs)
    if not mapping_matches(current, record.installed) then
        return
    end

    pcall(vim.keymap.del, record.mode, current.lhs, { buffer = bufnr })
    if record.previous then
        local rhs = record.previous.callback
            or (record.previous.rhs ~= "" and record.previous.rhs or "<Nop>")
        if rhs then
            pcall(
                vim.keymap.set,
                record.mode,
                record.previous.lhs or record.lhs,
                rhs,
                mapping_opts(bufnr, record.previous)
            )
        end
    end
end

function M.set_buffer_option(bufnr, name, value)
    bufnr = normalize_bufnr(bufnr)
    local state = state_for(bufnr)
    local option = state.options[name]
    if not option then
        option = {
            previous = vim.bo[bufnr][name],
        }
        state.options[name] = option
    end

    vim.bo[bufnr][name] = value
    option.installed = value
end

function M.set_window_option(bufnr, winid, name, value)
    bufnr = normalize_bufnr(bufnr)
    winid = winid or vim.api.nvim_get_current_win()
    if
        not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return false
    end

    window_state[winid] = window_state[winid] or {}
    window_state[winid][bufnr] = window_state[winid][bufnr] or { options = {} }
    local state = window_state[winid][bufnr]
    local option = state.options[name]
    if not option then
        option = {
            previous = vim.wo[winid][name],
        }
        state.options[name] = option
    end

    vim.wo[winid][name] = value
    option.installed = value
    return true
end

function M.set_buffer_mapping(bufnr, mode, lhs, rhs, opts)
    bufnr = normalize_bufnr(bufnr)
    if lhs == nil or lhs == false or lhs == "" then
        return false
    end

    opts = vim.tbl_extend("force", opts or {}, { buffer = bufnr })
    local state = state_for(bufnr)
    for _, one_mode in ipairs(expand_modes(mode)) do
        local key = one_mode .. "\n" .. lhs
        local record = state.mappings[key]
        if not record then
            record = {
                mode = one_mode,
                lhs = lhs,
                previous = current_buffer_mapping(bufnr, one_mode, lhs),
            }
            state.mappings[key] = record
        end

        vim.keymap.set(one_mode, lhs, rhs, opts)
        record.installed =
            mapping_identity(current_buffer_mapping(bufnr, one_mode, lhs))
    end

    return true
end

function M.restore_buffer_mappings(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local state = buffer_state[bufnr]
    if not state or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    for _, record in pairs(state.mappings) do
        restore_mapping(bufnr, record)
    end
    state.mappings = {}
end

function M.restore(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local state = buffer_state[bufnr]
    if state and vim.api.nvim_buf_is_valid(bufnr) then
        for name, option in pairs(state.options) do
            if vim.bo[bufnr][name] == option.installed then
                vim.bo[bufnr][name] = option.previous
            end
        end

        for _, record in pairs(state.mappings) do
            restore_mapping(bufnr, record)
        end
    end
    buffer_state[bufnr] = nil

    for winid, by_buffer in pairs(window_state) do
        local win_state = by_buffer[bufnr]
        if
            win_state
            and vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == bufnr
        then
            for name, option in pairs(win_state.options or {}) do
                if vim.wo[winid][name] == option.installed then
                    vim.wo[winid][name] = option.previous
                end
            end
        end
        by_buffer[bufnr] = nil
        if next(by_buffer) == nil then
            window_state[winid] = nil
        end
    end
end

function M.forget_window(winid)
    window_state[tonumber(winid) or winid] = nil
end

function M.reset()
    buffer_state = {}
    window_state = {}
end

return M
