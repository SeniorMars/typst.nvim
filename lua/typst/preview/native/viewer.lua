local events = require("typst.core.events")
local native_state = require("typst.preview.native.state")
local viewer_api = require("typst.viewer.generic")
local viewer_service = require("typst.project.services.viewer")

local M = {}

function M.open_output(project, opts, resolved)
    if type(resolved) == "table" and resolved.ok == false then
        return resolved
    end
    local path = resolved.path
    local export = resolved.export
    path = viewer_api.open(project, { path = path })
    local viewer_state = viewer_service.get(project) or {}
    native_state.record(project, "viewer", opts, {
        cwd = viewer_state.cwd,
        last_output = path,
        last_export = export,
        clear = {
            "last_url",
            "active_url",
            "active_output",
            "active_export",
            "active_transport",
            "active_shell",
            "active_server_port",
        },
    }, false)
    events.emit("TypstPreviewOpened", project, {
        backend = "viewer",
        mode = opts and opts.mode or nil,
        output = path,
        export = export,
    })
    return path
end

return M
