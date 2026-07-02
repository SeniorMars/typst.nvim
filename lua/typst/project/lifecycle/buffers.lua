local core_lifecycle = require("typst.core.lifecycle")
local ftplugin_state = require("typst.core.ftplugin_state")
local log = require("typst.core.log")
local project = require("typst.project")

local M = {}

local last_text_dirty_ticks = {}

local function toc_module()
    return require("typst.navigation.toc")
end

local function follow_open_toc(attached, bufnr)
    local toc = toc_module()
    if toc.is_open(attached) then
        toc.follow(attached, bufnr)
    end
end

local function schedule_follow_open_toc(attached, bufnr)
    toc_module().schedule_follow(attached, bufnr)
end

local function should_mark_dirty_for_buffer(attached, args)
    if args.event ~= "TextChanged" and args.event ~= "TextChangedI" then
        return true
    end

    local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, args.buf)
    if not ok then
        return true
    end

    local key = ("%s:%d"):format(attached.key or "", args.buf)
    if last_text_dirty_ticks[key] == changedtick then
        return false
    end

    last_text_dirty_ticks[key] = changedtick
    return true
end

local function clear_dirty_ticks_for_buffer(bufnr)
    local suffix = ":" .. tostring(bufnr)
    for key in pairs(last_text_dirty_ticks) do
        if key:sub(-#suffix) == suffix then
            last_text_dirty_ticks[key] = nil
        end
    end
end

--- Forget text-change debounce state for a buffer or one project/buffer pair.
---@param bufnr integer Buffer whose local debounce entries should be removed.
---@param project_key? string Project key to narrow cleanup.
function M.forget(bufnr, project_key)
    if project_key then
        last_text_dirty_ticks[("%s:%d"):format(project_key, bufnr)] = nil
        return
    end
    clear_dirty_ticks_for_buffer(bufnr)
end

--- Clear all lifecycle buffer-local debounce state.
function M.reset()
    last_text_dirty_ticks = {}
end

--- Return tracked debounce entry count for tests and health checks.
---@return integer count Active debounce entries.
function M._dirty_tick_count()
    return vim.tbl_count(last_text_dirty_ticks)
end

local function set_omnifunc_if_empty(bufnr)
    if vim.bo[bufnr].omnifunc == "" then
        ftplugin_state.set_buffer_option(
            bufnr,
            "omnifunc",
            "v:lua.typst_nvim_omnifunc"
        )
    end
end

local function attached_buffers()
    local seen = {}
    local buffers = {}
    for _, state in pairs(project.all()) do
        for bufnr in pairs(state.bufs or {}) do
            if not seen[bufnr] then
                seen[bufnr] = true
                buffers[#buffers + 1] = bufnr
            end
        end
    end
    table.sort(buffers)
    return buffers
end

function M.install(api, bufnr)
    clear_dirty_ticks_for_buffer(bufnr)
    require("typst.edit.mappings").apply(bufnr)
    core_lifecycle.apply_buffer_features(bufnr)
    set_omnifunc_if_empty(bufnr)

    local group = vim.api.nvim_create_augroup(
        core_lifecycle.buffer_augroup_name(bufnr),
        { clear = true }
    )
    -- Use one augroup per buffer so reloads replace lifecycle handlers instead
    -- of stacking duplicate TOC refreshes, index invalidations, and detaches.
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
        group = group,
        buffer = bufnr,
        callback = function(args)
            core_lifecycle.apply_buffer_features(args.buf)
            local attached = project.get(args.buf)
            if attached then
                follow_open_toc(attached, args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        buffer = bufnr,
        callback = function(args)
            local attached = project.get(args.buf)
            if attached then
                follow_open_toc(attached, args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        buffer = bufnr,
        callback = function(args)
            local attached = project.get(args.buf)
            if attached then
                schedule_follow_open_toc(attached, args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd(
        { "TextChanged", "TextChangedI", "BufWritePost" },
        {
            group = group,
            buffer = bufnr,
            callback = function(args)
                local attached = project.get(args.buf)
                if attached then
                    if should_mark_dirty_for_buffer(attached, args) then
                        require("typst.index").mark_dirty(
                            attached,
                            "buffer changed"
                        )
                    end
                    toc_module().schedule_refresh(attached)
                end
            end,
        }
    )
    vim.api.nvim_create_autocmd("BufFilePost", {
        group = group,
        buffer = bufnr,
        callback = function(args)
            -- Neovim fires this after :saveas or file rename. Move persisted
            -- main-file choices before resolving again so the new path keeps the
            -- user's explicit main.
            core_lifecycle.migrate_persisted_main_for_rename(
                args.buf,
                project.get(args.buf)
            )
            api.attach(args.buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufHidden", {
        group = group,
        buffer = bufnr,
        callback = function(args)
            local policy = vim.bo[args.buf].bufhidden
            if policy == "unload" or policy == "delete" or policy == "wipe" then
                api.detach(args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
        group = group,
        buffer = bufnr,
        callback = function(args)
            api.detach(args.buf)
        end,
    })
end

function M.reapply_attached_buffers()
    local summary = {
        applied = 0,
        skipped = 0,
    }
    for _, bufnr in ipairs(attached_buffers()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            ftplugin_state.restore_buffer_mappings(bufnr)
            require("typst.edit.mappings").apply(bufnr)
            core_lifecycle.apply_buffer_features(bufnr, { force = true })
            set_omnifunc_if_empty(bufnr)
            summary.applied = summary.applied + 1
        else
            summary.skipped = summary.skipped + 1
        end
    end

    if summary.applied > 0 or summary.skipped > 0 then
        log.add(
            "info",
            "reapplied setup state to attached Typst buffers",
            summary
        )
    end
    return summary
end

return M
