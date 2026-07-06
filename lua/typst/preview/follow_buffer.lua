local config = require("typst.config")
local log = require("typst.core.log")
local project_store = require("typst.project.store")
local preview_service = require("typst.project.services.preview")

local M = {}

local group = nil
local scheduled = {}

local function typst_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if vim.bo[bufnr].filetype == "typst" then
        return true
    end
    return vim.api.nvim_buf_get_name(bufnr):match("%.typ$") ~= nil
end

local function enabled()
    return (config.unsafe_get().preview or {}).follow_buffer == true
end

local function active_native_browser_project(current)
    local found = nil
    local count = 0
    for _, project in pairs(project_store.all()) do
        local preview = preview_service.get(project) or {}
        if
            preview.active == true
            and preview.active_backend == "native-browser"
        then
            if current and project.key == current.key then
                return project, 1
            end
            found = found or project
            count = count + 1
        end
    end
    return found, count
end

function M.on_buffer(bufnr)
    if not enabled() or not typst_buffer(bufnr) then
        return nil
    end

    local current = require("typst.project.context").resolve({
        bufnr = bufnr,
    }, {
        create = false,
        settle_pending = true,
    })
    if not current then
        return nil
    end

    local active, active_count = active_native_browser_project(current)
    if not active or active.key == current.key then
        return nil
    end
    if active_count > 1 then
        log.add(
            "debug",
            "preview follow_buffer skipped multiple active routes",
            {
                main = current.main,
                active_routes = active_count,
            }
        )
        return nil
    end

    return require("typst.preview.native").follow_buffer(active, current, {
        bufnr = bufnr,
    })
end

local function schedule(bufnr)
    if scheduled[bufnr] then
        return
    end
    scheduled[bufnr] = true
    vim.schedule(function()
        scheduled[bufnr] = nil
        M.on_buffer(bufnr)
    end)
end

function M.setup()
    if not enabled() then
        M.reset()
        return {
            ok = true,
            installed = false,
            reason = "disabled",
        }
    end

    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    group = vim.api.nvim_create_augroup("typst_nvim_preview_follow_buffer", {
        clear = true,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = group,
        callback = function(args)
            if not enabled() then
                return
            end
            schedule(args.buf)
        end,
    })
    return {
        ok = true,
        installed = true,
    }
end

function M.reset()
    scheduled = {}
    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        group = nil
    end
end

return M
