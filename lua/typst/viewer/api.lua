local cursor_position = require("typst.completion.position")
local cleanup = require("typst.viewer.cleanup")
local preview_cache = require("typst.preview.cache")
local preview_results = require("typst.preview.results")
local typst_preview = require("typst.preview.controller")
local preview_service = require("typst.project.services.preview")
local path_util = require("typst.core.path")
local viewer = require("typst.viewer.generic")

local M = {}

-- Viewer commands and preview-facing public command orchestration enter here.
-- Keep this as the stable path until the public command/API surface is frozen.

local notify_user = require("typst.core.notify").user

local function stop_failed(result)
    return preview_results.stop_failed(result)
end

local function stop_failure_message(result, fallback)
    if type(result) ~= "table" then
        return fallback
    end
    return result.message
        or (result.stopped == false and "Typst preview stop was not confirmed")
        or fallback
end

local function source_position(opts)
    opts = opts or {}
    if opts.line or opts.column then
        return {
            line = opts.line or vim.fn.line("."),
            column = opts.column or vim.fn.col("."),
        }
    end

    local resolved = cursor_position.resolve(opts)
    if resolved then
        return {
            line = resolved.row + 1,
            column = resolved.col + 1,
        }
    end

    return {
        line = vim.fn.line("."),
        column = vim.fn.col("."),
    }
end

--- Open the rendered output for a project with the configured viewer.
---@param state table Project state whose compiler output should be opened.
---@param opts? table Viewer options accepted for API symmetry.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return string|false|table path Opened output path, false when no viewer opened it, or failure payload.
function M.view(state, opts, notify)
    local path = viewer.open(state)
    if type(path) == "table" and path.ok == false then
        notify_user(
            notify,
            path.message or "Typst viewer is unavailable",
            path.notify_level or vim.log.levels.WARN
        )
        return path
    end
    if path ~= false then
        notify_user(
            notify,
            ("Opened %s"):format(path_util.relpath(path, state.root))
        )
    end
    return path
end

--- Forward-search from the current source location to the viewer or preview.
---@param state table Project state whose main/output paths define the sync context.
---@param opts? table Forward-search options such as line, column, path, and notify.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|boolean|string|nil result Backend sync result or failure payload.
function M.view_forward(state, opts, notify)
    opts = opts or {}
    local result = viewer.forward(state, opts)
    if
        type(result) == "table"
        and result.ok == false
        and result.reason == "unsupported"
    then
        -- VimTeX users expect forward search to work through the active preview
        -- when the PDF viewer has no direct forward-search backend.
        local viewer_result = result
        local preview_result = typst_preview.forward(state, opts)
        if type(preview_result) == "table" and preview_result.ok == false then
            if preview_result.reason ~= "unsupported" then
                result = preview_result
            else
                result = viewer_result
            end
        else
            result = preview_result
        end
    end

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst viewer forward search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false then
        local position = source_position(opts)
        notify_user(
            notify,
            ("Forwarded %s:%d:%d"):format(
                path_util.relpath(state.main, state.root),
                position.line,
                position.column
            )
        )
    end

    return result
end

--- Jump from viewer-reported coordinates back into a Typst source buffer.
---@param state table Project state used to resolve inverse-search paths.
---@param opts? table Inverse-search options such as path, line, column, and notify.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|boolean|nil result Source location result or failure payload.
function M.view_inverse(state, opts, notify)
    opts = opts or {}
    local result = viewer.inverse(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst viewer inverse search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false and opts.notify ~= false then
        local location = type(result) == "table" and result or {}
        notify_user(
            notify,
            ("Viewer inverse jump %s:%d:%d"):format(
                path_util.relpath(
                    location.path or opts.path or state.main,
                    state.root
                ),
                location.line or opts.line or 1,
                location.column or opts.column or 1
            )
        )
    end

    return result
end

--- Return capabilities advertised by the configured PDF viewer backend.
---
--- Capability lookup is intentionally project-free so statusline/config UIs can
--- call it from scratch or non-Typst buffers without attaching a project.
---@return table capabilities Viewer backend capability flags.
function M.viewer_capabilities()
    return viewer.capabilities()
end

--- Return capabilities advertised by the Typst preview backend for a project.
---@param state table Project state used to inspect preview configuration.
---@return table capabilities Preview backend capability flags.
function M.preview_capabilities(state)
    return typst_preview.capabilities(state)
end

--- Remove temporary Typst artifacts and optionally the owned compiler output.
---@param state table Project state whose artifacts should be cleaned.
---@param opts? table Clean options; `all`/`outputs` permit output deletion.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary with deleted output and temporary paths.
function M.clean(state, opts, notify)
    return cleanup.clean(state, opts, notify)
end

--- Remove temporary artifacts and request output cleanup for a project.
--- Changed or unowned outputs are skipped unless `opts.force` is true.
---@param state table Project state whose output should be cleaned.
---@param opts? table Clean options forwarded to `clean`.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary from `clean`.
function M.clean_output(state, opts, notify)
    return cleanup.clean_output(state, opts, notify)
end

--- Remove preview-owned cache artifacts for a project.
---@param state table Project state whose preview artifacts should be cleaned.
---@param opts? table Clean controls; `force=true` removes modified owned artifacts.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary for preview-owned artifacts.
function M.clean_preview(state, opts, notify)
    return cleanup.clean_preview(state, opts, notify)
end

--- Start Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean|string|nil result Preview backend result.
function M.preview(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.open(state, opts)
    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview is unavailable",
            vim.log.levels.WARN
        )
    elseif result == true then
        notify_user(
            notify,
            ("Previewing %s"):format(path_util.relpath(state.main, state.root))
        )
    end
    return result
end

--- Open the native browser preview target regardless of the default target.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table|boolean|string|nil result Preview backend result.
function M.preview_open_browser(state, opts, notify)
    opts = vim.tbl_extend("force", opts or {}, {
        native = "browser",
    })
    return M.preview(state, opts, notify)
end

--- Refresh an active preview backend from Neovim.
---@param state table Project state whose preview should reload.
---@param opts? table Refresh options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table|boolean|nil result Refresh result or unsupported payload.
function M.preview_reload(state, opts, notify)
    opts = opts or {}
    local preview_state = preview_service.get(state) or {}
    if preview_state.active ~= true then
        local result = {
            ok = false,
            reason = "inactive_preview",
            message = "No active Typst preview is available to reload",
        }
        notify_user(notify, result.message, vim.log.levels.WARN)
        return result
    end

    local result = typst_preview.refresh(state, {
        code = 0,
        manual = true,
        generation = vim.uv.hrtime(),
    }, opts)
    if type(result) == "table" and result.pending == true then
        if type(result.on_finish) == "function" then
            result:on_finish(function(finished)
                if type(finished) == "table" and finished.ok == false then
                    notify_user(
                        notify,
                        finished.message or "Typst preview reload failed",
                        vim.log.levels.WARN
                    )
                else
                    notify_user(notify, "Reloaded Typst preview")
                end
            end)
        end
        return result
    end
    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview reload failed",
            vim.log.levels.WARN
        )
    else
        notify_user(notify, "Reloaded Typst preview")
    end
    return result
end

--- Return preview backend/cache status for a project.
---@param state table Project state whose preview should be inspected.
---@param opts? table Status display options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table status Preview status payload.
function M.preview_status(state, opts, notify)
    opts = opts or {}
    local status = typst_preview.status(state, { raw = true, cache = true })
    local cache_status = status.cache or preview_cache.status(state)
    local lines = require("typst.ui.reports").preview_status_lines(state)
    if opts.echo ~= false then
        require("typst.ui.reports").echo_lines(lines)
    elseif opts.notify ~= false then
        notify_user(
            notify,
            ("Preview %s, cache %d entries"):format(
                status.active and "active" or "inactive",
                cache_status.count
            )
        )
    end
    return {
        ok = true,
        active = status.active == true,
        backend = status.backend,
        status = status.status,
        cache = cache_status,
        lines = lines,
        preview = status,
    }
end

--- Stop Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview stop options. Pending handles must eventually report `stopped=true` or `ok=false`.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean|string|nil result Preview backend result.
function M.preview_stop(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.stop(state, opts)

    if stop_failed(result) then
        if opts.notify ~= false then
            notify_user(
                notify,
                stop_failure_message(
                    result,
                    "Typst preview stop is unavailable"
                ),
                vim.log.levels.WARN
            )
        end
    elseif result ~= false and opts.notify ~= false then
        notify_user(
            notify,
            ("Preview stopped for %s"):format(
                path_util.relpath(state.main, state.root)
            )
        )
    end

    return result
end

--- Toggle Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview toggle options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean|string|nil result Preview backend result.
function M.preview_toggle(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.toggle(state, opts)

    if stop_failed(result) then
        notify_user(
            notify,
            stop_failure_message(result, "Typst preview toggle is unavailable"),
            vim.log.levels.WARN
        )
    elseif type(result) == "table" and result.pending == true then
        notify_user(
            notify,
            ("Preview opening for %s"):format(
                path_util.relpath(state.main, state.root)
            )
        )
    elseif (preview_service.get(state) or {}).active then
        notify_user(
            notify,
            ("Previewing %s"):format(path_util.relpath(state.main, state.root))
        )
    else
        notify_user(
            notify,
            ("Preview stopped for %s"):format(
                path_util.relpath(state.main, state.root)
            )
        )
    end

    return result
end

--- Run inverse search through the Typst preview integration.
---@param state table Project state used to resolve source locations.
---@param opts? table Preview inverse-search options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean|nil result Preview inverse-search result or failure payload.
function M.preview_inverse(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.inverse(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview inverse search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false and opts.notify ~= false then
        local location = type(result) == "table" and result or {}
        notify_user(
            notify,
            ("Preview inverse jump %s:%d:%d"):format(
                path_util.relpath(location.path or state.main, state.root),
                location.line or opts.line or 1,
                location.column or opts.column or 1
            )
        )
    end

    return result
end

return M
