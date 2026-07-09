local config = require("typst.config")
local interface = require("typst.preview.backends.interface")
local log = require("typst.core.log")
local native = require("typst.preview.native")
local preview_service = require("typst.project.services.preview")
local viewer_backend = require("typst.preview.backends.viewer")

local M = {}

local function browser_failed(result)
    return result == false
        or (type(result) == "table" and result.ok == false)
end

local function failure_message(result)
    if type(result) == "table" then
        return result.message or result.reason or result.error
    end
    return result
end

local function open_with_viewer_fallback(project, opts)
    local ok, result = xpcall(function()
        return native.open_browser(project, opts)
    end, debug.traceback)
    if ok and not browser_failed(result) then
        return result
    end

    log.add("warn", "native browser preview unavailable; using viewer", {
        main = project.main,
        error = failure_message(result),
        url = type(result) == "table" and result.url or nil,
    })
    local browser_failure = ok
            and type(result) == "table"
            and result.ok == false
            and result
        or nil
    local viewer_result = viewer_backend.create():open(project, opts)
    if browser_failure then
        preview_service.set(project, {
            last_error = browser_failure,
            last_failed_url = browser_failure.url,
        })
    end
    return viewer_result
end

---Create a backend wrapper for native browser preview.
---@param opts? table Backend construction options.
---@return table backend Browser preview backend.
function M.create(opts)
    opts = opts or {}
    return interface.create({
        name = "native-browser",
        kind = "browser",
        advanced = true,

        open = function(_, project, open_opts)
            if opts.fallback == "viewer" then
                return open_with_viewer_fallback(project, open_opts)
            end
            return native.open_browser(project, open_opts)
        end,

        stop = function(_, project)
            native.stop(project)
            return {
                ok = true,
                stopped = true,
                backend = "native-browser",
            }
        end,

        refresh = function(_, project, compile_result, refresh_opts)
            return native.refresh(project, compile_result, refresh_opts)
        end,

        capabilities = function()
            local preview = config.unsafe_get().preview or {}
            return {
                source_maps = preview.source_maps ~= false,
                server = preview.browser and preview.browser.server ~= false,
                file_shell = true,
                follow_buffer = true,
            }
        end,
    })
end

return M
