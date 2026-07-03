local core_lifecycle = require("typst.core.lifecycle")
local log = require("typst.core.log")
local project = require("typst.project")
local attachment_editing = require("typst.project.attachments.editing")
local attachment_index = require("typst.project.attachments.index")
local attachment_toc = require("typst.project.attachments.toc")
local project_store = require("typst.project.store")

local M = {}

function M.forget(bufnr, project_key)
    attachment_index.forget(bufnr, project_key)
end

--- Clear all lifecycle buffer-local debounce state.
function M.reset()
    attachment_index.reset()
end

--- Return tracked debounce entry count for tests and health checks.
---@return integer count Active debounce entries.
function M._dirty_tick_count()
    return attachment_index.count()
end

local function attached_buffers()
    local seen = {}
    local buffers = {}
    for _, state in pairs(project_store.all()) do
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
    attachment_index.forget(bufnr)
    attachment_editing.apply(bufnr)

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
                attachment_toc.follow_open(attached, args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        buffer = bufnr,
        callback = function(args)
            local attached = project.get(args.buf)
            if attached then
                attachment_toc.follow_open(attached, args.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        buffer = bufnr,
        callback = function(args)
            local attached = project.get(args.buf)
            if attached then
                attachment_toc.schedule_follow_open(attached, args.buf)
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
                    if attachment_index.should_mark_dirty(attached, args) then
                        require("typst.index").mark_dirty(
                            attached,
                            "buffer changed"
                        )
                    end
                    attachment_toc.schedule_refresh(attached)
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
            attachment_editing.reapply(bufnr)
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
