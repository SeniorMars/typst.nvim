local events = require("typst.core.events")
local log = require("typst.core.log")
local preview_service = require("typst.project.services.preview")

local M = {}

local function typst_preview_command(mode)
    local command = "TypstPreview"
    if mode and mode ~= "" then
        command = command .. " " .. mode
    end
    return { command }
end

--- Record preview backend metadata on project state.
---@param project table Project state whose preview service is mutated.
---@param backend string Backend label.
---@param opts? table Preview options containing mode.
---@param command? string[] Command used by delegated preview backend.
---@param cwd? string Working directory used by delegated preview backend.
---@param active boolean True when the backend is now active.
function M.record(project, backend, opts, command, cwd, active)
    local fields = {
        clear = {
            "status",
            "last_result",
            "last_error",
            "stop_prune_reason",
            "stopping",
        },
        last_backend = backend,
        last_mode = opts and opts.mode or nil,
        last_command = command,
        last_cwd = cwd,
        active = active,
    }

    if active then
        fields.active_backend = backend
        fields.active_mode = fields.last_mode
        fields.active_command = command and vim.deepcopy(command) or nil
        fields.active_cwd = cwd
    end
    preview_service.set(project, fields)
end

--- Refresh last-preview metadata when reusing an active preview.
---@param project table Project state whose preview service is mutated.
---@param opts? table Preview options containing mode.
function M.record_reused(project, opts)
    local preview = preview_service.get(project) or {}
    local fields = {}
    if not preview.active_backend then
        fields.active_backend = preview.last_backend
        fields.active_mode = preview.last_mode
        fields.active_command = preview.last_command
                and vim.deepcopy(preview.last_command)
            or nil
        fields.active_cwd = preview.last_cwd
    end

    if
        (
            not (fields.active_mode or preview.active_mode)
            or (fields.active_mode or preview.active_mode) == ""
        )
        and opts.mode
        and opts.mode ~= ""
    then
        fields.active_mode = opts.mode
        if
            (fields.active_backend or preview.active_backend)
            == "typst-preview.nvim"
        then
            fields.active_command = typst_preview_command(opts.mode)
            fields.active_cwd = fields.active_cwd
                or preview.active_cwd
                or project.root
        end
    end

    fields.last_backend = fields.active_backend or preview.active_backend
    fields.last_mode = fields.active_mode or preview.active_mode
    fields.last_command = (fields.active_command or preview.active_command)
            and vim.deepcopy(fields.active_command or preview.active_command)
        or nil
    fields.last_cwd = fields.active_cwd or preview.active_cwd
    preview_service.set(project, fields)
end

--- Mark preview inactive and emit the stopped event.
---@param project table Project state whose preview service is mutated.
---@param backend? string Backend label to record.
---@param command? string[] Command used by delegated preview backend.
---@param cwd? string Working directory used by delegated preview backend.
function M.emit_stopped(project, backend, command, cwd)
    local preview = preview_service.get(project) or {}
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
        last_backend = backend or preview.last_backend,
        last_command = command,
        last_cwd = cwd,
    })
    preview = preview_service.get(project) or preview
    log.add("info", "preview stopped", {
        backend = preview.last_backend,
        command = command,
        cwd = cwd,
        main = project.main,
    })
    events.emit("TypstPreviewStopped", project, {
        backend = preview.last_backend,
        command = command,
    })
end

--- Clear preview state without asking the backend to stop.
---@param project table Project state whose preview service is mutated.
---@param opts? table Clear options such as reason/lifecycle.
---@return boolean cleared True when active preview state was cleared.
function M.clear(project, opts)
    opts = opts or {}
    local preview = preview_service.get(project) or {}
    if not project or preview.active ~= true then
        return false
    end

    local backend = preview.active_backend or preview.last_backend
    local command = preview.active_command or preview.last_command
    local cwd = preview.active_cwd or preview.last_cwd
    local mode = preview.active_mode or preview.last_mode

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
        last_backend = backend,
        last_command = command and vim.deepcopy(command) or nil,
        last_cwd = cwd,
        last_mode = mode,
    })

    log.add("warn", "preview state cleared without backend stop", {
        main = project.main,
        backend = backend,
        reason = opts.reason,
        lifecycle = opts.lifecycle == true,
    })
    events.emit("TypstPreviewStopped", project, {
        backend = backend,
        command = command and vim.deepcopy(command) or nil,
        cwd = cwd,
        mode = mode,
        reason = opts.reason,
        lifecycle = opts.lifecycle == true,
        forced = true,
    })

    return true
end

return M
