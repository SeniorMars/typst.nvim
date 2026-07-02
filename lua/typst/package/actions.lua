local M = {}

local open_helper = require("typst.core.open")
local resource_markdown = require("typst.package.resource_markdown")
local util = require("typst.core.util")
local windows = require("typst.core.windows")

local resources_buf = nil
local state_by_buf = {}

-- Package resources use a single reusable nofile buffer. The buffer-local state
-- keeps keymaps simple while avoiding one scratch buffer per lookup.

local function valid_buf(bufnr)
    return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function ensure_buffer()
    if valid_buf(resources_buf) then
        return resources_buf
    end

    resources_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[resources_buf].buftype = "nofile"
    vim.bo[resources_buf].bufhidden = "hide"
    vim.bo[resources_buf].swapfile = false
    vim.bo[resources_buf].filetype = "markdown"
    pcall(
        vim.api.nvim_buf_set_name,
        resources_buf,
        "typst.nvim package resources"
    )
    return resources_buf
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
        desc = "Close Typst package resources",
    })

    vim.keymap.set("n", "<CR>", function()
        local state = state_by_buf[bufnr]
        if not state or not state.results then
            return
        end

        local line = vim.api.nvim_get_current_line()
        local index = tonumber(line:match("^%s*(%d+)%."))
        local result = index and state.results[index]
        if result then
            M.open(result)
        end
    end, {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package resource result",
    })

    vim.keymap.set("n", "s", function()
        local state = state_by_buf[bufnr]
        local source = state and state.result and state.result.source
        if source and source.path and vim.fn.filereadable(source.path) == 1 then
            util.edit_existing_or_path(source.path)
        end
    end, {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package source",
    })

    vim.keymap.set("n", "m", function()
        local state = state_by_buf[bufnr]
        local manual = state
            and state.result
            and state.result.manuals
            and state.result.manuals[1]
        if manual and manual.path and vim.fn.filereadable(manual.path) == 1 then
            if manual.path:match("%.typ$") or manual.path:match("%.md$") then
                util.edit_existing_or_path(manual.path)
            elseif vim.ui and vim.ui.open then
                local object, err = open_helper.ui_open(manual.path)
                if not object then
                    vim.notify(
                        ("Could not open package manual: %s"):format(err),
                        vim.log.levels.WARN,
                        {
                            title = "typst.nvim",
                        }
                    )
                end
            end
        end
    end, {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package manual",
    })

    local function open_link(name)
        return function()
            local state = state_by_buf[bufnr]
            local url = state
                and state.result
                and state.result.links
                and state.result.links[name]
            if url then
                local opened, err = open_helper.url(url)
                if not opened then
                    vim.notify(
                        ("Could not open package link: %s"):format(err),
                        vim.log.levels.WARN,
                        {
                            title = "typst.nvim",
                        }
                    )
                end
            end
        end
    end

    vim.keymap.set("n", "r", open_link("repository"), {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package repository",
    })
    vim.keymap.set("n", "h", open_link("homepage"), {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package homepage",
    })
    vim.keymap.set("n", "u", open_link("reference"), {
        buffer = bufnr,
        silent = true,
        desc = "Open Typst package Universe page",
    })
end

function M.open(result, opts)
    opts = opts or {}
    local bufnr = ensure_buffer()
    state_by_buf[bufnr] = {
        result = result,
    }
    set_lines(bufnr, resource_markdown.resource(result))
    apply_keymaps(bufnr)
    show_buffer(bufnr, opts)
    return bufnr
end

function M.open_search(results, query, opts)
    opts = opts or {}
    local bufnr = ensure_buffer()
    state_by_buf[bufnr] = {
        query = query,
        results = results,
    }
    set_lines(bufnr, resource_markdown.search(results, query))
    apply_keymaps(bufnr)
    show_buffer(bufnr, opts)
    return bufnr
end

function M.current_result(bufnr)
    bufnr = bufnr or resources_buf
    local state = valid_buf(bufnr) and state_by_buf[bufnr]
    return state and state.result
end

function M.reset()
    if valid_buf(resources_buf) then
        pcall(vim.api.nvim_buf_delete, resources_buf, { force = true })
    end
    resources_buf = nil
    state_by_buf = {}
end

return M
