local config = require("typst.config")
local log = require("typst.core.log")
local browser = require("typst.preview.native.browser")
local native_pending = require("typst.preview.native.pending")
local preview_service = require("typst.project.services.preview")
local session = require("typst.preview.native.session")
local viewer = require("typst.preview.native.viewer")

local M = {}

function M.open_viewer(project, opts)
    return native_pending.with_output(
        project,
        "viewer",
        opts,
        function(resolved)
            return viewer.open_output(project, opts, resolved)
        end
    )
end

function M.open_browser(project, opts)
    return native_pending.with_output(
        project,
        "browser",
        opts,
        function(resolved)
            return browser.open_output(project, opts, resolved)
        end
    )
end

function M.open(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native = opts.native or opts.target or preview.native or "viewer"
    if native == "view" then
        native = "viewer"
    end

    if native == "viewer" then
        return M.open_viewer(project, opts)
    end

    if native == "browser" then
        return M.open_browser(project, opts)
    end

    if native == "auto" then
        local ok, result = xpcall(function()
            return M.open_browser(project, opts)
        end, debug.traceback)
        if
            ok
            and result ~= false
            and not (type(result) == "table" and result.ok == false)
        then
            return result
        end
        log.add("warn", "native browser preview unavailable; using viewer", {
            main = project.main,
            error = type(result) == "table" and result.message or result,
            url = type(result) == "table" and result.url or nil,
        })
        local browser_failure = type(result) == "table"
                and result.ok == false
                and result
            or nil
        local viewer_result = M.open_viewer(project, opts)
        if browser_failure then
            preview_service.set(project, {
                last_error = browser_failure,
                last_failed_url = browser_failure.url,
            })
        end
        return viewer_result
    end

    return {
        ok = false,
        reason = "invalid_preview_native",
        message = 'preview.native must be "browser", "viewer", or "auto"',
        native = native,
    }
end

function M.follow_buffer(project, next_project, opts)
    if not project or not next_project or project.key == next_project.key then
        return nil
    end
    opts = vim.tbl_extend("force", {
        follow_buffer = true,
    }, opts or {})
    return native_pending.with_output(
        next_project,
        "browser",
        opts,
        function(resolved)
            return browser.follow_output(project, next_project, opts, resolved)
        end
    )
end

function M.refresh(project, result, opts)
    return browser.refresh(project, result, opts)
end

function M.stop(project)
    browser.cleanup(project)
    return true
end

function M.browser_url(project)
    return session.browser_url(project)
end

return M
