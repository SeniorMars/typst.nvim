local preview_service = require("typst.project.services.preview")

local M = {}

function M.record(project, backend, opts, fields, active)
    fields = fields or {}
    local cwd = fields.cwd
    local service_fields = vim.deepcopy(fields)
    service_fields.cwd = nil
    require("typst.preview.state_machine").record(
        project,
        backend,
        opts,
        nil,
        cwd,
        active
    )
    preview_service.set(project, service_fields)
end

function M.clear_followed_project(project)
    preview_service.set(project, {
        clear = {
            "active_backend",
            "active_mode",
            "active_command",
            "active_cwd",
            "active_url",
            "active_output",
            "active_export",
            "active_transport",
            "active_shell",
            "active_server_port",
            "status",
            "last_result",
            "last_error",
            "stop_prune_reason",
            "stopping",
        },
        active = false,
        last_backend = "native-browser-followed",
    })
end

return M
