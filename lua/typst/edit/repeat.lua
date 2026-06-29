local M = {}
local ftplugin_state = require("typst.core.ftplugin_state")

local state_key = "typst_repeat_state"

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function changedtick(bufnr)
    local ok, value = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
    if ok then
        return value
    end

    return vim.b[bufnr].changedtick
end

local function command_from_keys(keys)
    if type(keys) ~= "string" or keys:sub(1, 1) ~= ":" then
        return nil
    end

    local command = keys:sub(2)
    command = command:gsub("<[cC][rR]>$", "")
    if command == "" then
        return nil
    end

    return command
end

local function native_dot(count)
    local prefix = count and count > 0 and tostring(count) or ""
    vim.cmd.normal({ args = { prefix .. "." }, bang = true })
end

local function execute_state(state)
    if state.command then
        vim.cmd(state.command)
        return
    end

    local rhs = vim.api.nvim_replace_termcodes(state.keys, true, false, true)
    vim.api.nvim_feedkeys(rhs, "n", false)
end

function M.set(keys, opts)
    opts = opts or {}
    if type(keys) ~= "string" or keys == "" then
        return false
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local rhs = vim.api.nvim_replace_termcodes(keys, true, false, true)
    local count = opts.count or vim.v.count

    if vim.fn.exists("*repeat#set") == 1 then
        pcall(vim.fn["repeat#set"], rhs, count)
    end

    vim.b[bufnr][state_key] = {
        keys = keys,
        command = command_from_keys(keys),
        changedtick = changedtick(bufnr),
    }

    return true
end

function M.repeat_last(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local state = vim.b[bufnr][state_key]
    local count = vim.v.count1

    if type(state) ~= "table" or state.changedtick ~= changedtick(bufnr) then
        native_dot(count == 1 and 0 or count)
        return false
    end

    for _ = 1, count do
        local ok, err = pcall(execute_state, state)
        if not ok then
            vim.notify(
                tostring(err),
                vim.log.levels.WARN,
                { title = "typst.nvim repeat" }
            )
            return false
        end
    end

    return true
end

function M.map(bufnr, lhs)
    bufnr = normalize_bufnr(bufnr)
    if lhs == nil or lhs == false or lhs == "" then
        return
    end

    ftplugin_state.set_buffer_mapping(bufnr, "n", lhs, function()
        return M.repeat_last({ bufnr = bufnr })
    end, {
        silent = true,
        desc = "Repeat last Typst structural edit or native change",
    })
end

function M.state(bufnr)
    bufnr = normalize_bufnr(bufnr)
    return vim.deepcopy(vim.b[bufnr][state_key])
end

function M.reset(bufnr)
    bufnr = normalize_bufnr(bufnr)
    vim.b[bufnr][state_key] = nil
end

return M
