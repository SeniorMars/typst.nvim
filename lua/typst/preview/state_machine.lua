local events = require("typst.core.events")
local log = require("typst.core.log")
local resource_manager = require("typst.runtime.resource_manager")
local project_store = require("typst.project.store")
local preview_service = require("typst.project.services.preview")

local M = {}

local open_generation = 0

local function typst_preview_command(mode)
    local command = "TypstPreview"
    if mode and mode ~= "" then
        command = command .. " " .. mode
    end
    return { command }
end

---Return the current preview service state.
---@param project table Project state.
---@return table state Preview service state.
function M.current(project)
    return preview_service.get(project) or {}
end

---Return whether preview is active for a project.
---@param project table Project state.
---@return boolean active True when active.
function M.is_active(project)
    return M.current(project).active == true
end

---Return whether preview open is pending for a project.
---@param project table Project state.
---@return boolean opening True when opening.
function M.is_opening(project)
    return M.current(project).opening == true
end

---Return the next preview-open generation.
---@return integer generation Preview open generation.
function M.next_generation()
    open_generation = open_generation + 1
    return open_generation
end

---Return why a preview epoch token is stale.
---@param token? table Resource-manager token.
---@return string? reason Stale reason.
function M.token_invalid_reason(token)
    if not token then
        return nil
    end
    local valid, reason = resource_manager.valid_token(token)
    if valid then
        return nil
    end
    return reason or "stale_preview_open"
end

---Return whether the pending-open record still owns project state.
---@param project table Project state.
---@param handle table Pending open handle.
---@param generation integer Open generation.
---@param token? table Resource-manager token.
---@return boolean current True when still current.
---@return string? reason Stale reason.
function M.pending_open_current(project, handle, generation, token)
    local stale_reason = M.token_invalid_reason(token)
    if stale_reason then
        return false, stale_reason
    end
    local preview = preview_service.get(project) or {}
    if
        preview.opening == true
        and preview.open_handle == handle
        and preview.open_generation == generation
        and (token == nil or preview.open_token == token)
    then
        return true
    end
    return false, "stale_preview_open"
end

---Return whether a project and pending-open record are both current.
---@param project table Project state.
---@param handle table Pending open handle.
---@param generation integer Open generation.
---@param token? table Resource-manager token.
---@return boolean current True when still current.
---@return string? reason Stale reason.
function M.project_open_current(project, handle, generation, token)
    if
        type(project) ~= "table"
        or project._typst_project_pruned == true
        or type(project.key) ~= "string"
    then
        return false, "project_changed"
    end

    local live = project_store.get(project.key)
    if live ~= project then
        return false, "project_changed"
    end
    if
        live
        and project.instance_id ~= nil
        and live.instance_id ~= project.instance_id
    then
        return false, "project_changed"
    end

    return M.pending_open_current(project, handle, generation, token)
end

---Record a preview stop failure while preserving active preview ownership.
---@param project table Project state.
---@param result any Stop failure result.
function M.to_stopping_failed(project, result)
    preview_service.set(project, {
        active = true,
        stopping = false,
        status = "stopping_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason)
            or result,
    })
end

---Record that preview stop is pending while preserving active ownership.
---@param project table Project state.
---@param fields? table Stop metadata.
function M.to_stopping(project, fields)
    fields = fields or {}
    preview_service.set(project, {
        active = true,
        stopping = true,
        status = "stopping",
        stop_handle = fields.handle,
    })
end

---Record an unconfirmed stop during lifecycle cleanup.
---@param project table Project state.
---@param result any Stop result.
---@param reason? string Prune/reset/exit reason.
function M.to_stop_unconfirmed(project, result, reason)
    preview_service.set(project, {
        active = true,
        stopping = true,
        status = "stopping_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason or "pending")
            or result,
        stop_prune_reason = reason,
    })
end

---Record an inactive/stopped preview state.
---@param project table Project state.
---@param backend? string Backend label.
---@param command? table|string Backend command.
---@param cwd? string Backend cwd.
---@param result? any Stop result.
---@return any result Original result.
function M.to_inactive(project, backend, command, cwd, result)
    M.emit_stopped(project, backend, command, cwd, result)
    return result
end

---Record an open failure and clear active/opening state.
---@param project table Project state.
---@param result any Open failure result.
function M.to_open_failed(project, result)
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
            "stopping",
            "opening",
            "open_handle",
            "open_generation",
            "open_token",
        },
        active = false,
        status = "open_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason)
            or result,
    })
end

---Record a pending preview open.
---@param project table Project state.
---@param opts? table Preview options.
---@param handle table Pending open handle.
---@param generation integer Open generation.
---@param token? table Resource-manager token.
function M.to_opening(project, opts, handle, generation, token)
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
            "stopping",
        },
        active = false,
        opening = true,
        status = "opening",
        last_backend = "callback",
        last_mode = opts and opts.mode or nil,
        open_handle = handle,
        open_generation = generation,
        open_token = token,
    })
end

---Clear current pending-open state after cancellation.
---@param project table Project state.
---@param result any Cancellation result.
function M.clear_pending_open(project, result)
    preview_service.set(project, {
        clear = {
            "opening",
            "open_handle",
            "open_generation",
            "open_token",
            "stopping",
            "status",
            "last_error",
        },
        active = false,
        last_result = result,
    })
end

---Record an unconfirmed pending-open cancellation.
---@param project table Project state.
---@param result any Cancellation result.
---@param status string Preview status.
function M.to_open_cancel_unconfirmed(project, result, status)
    preview_service.set(project, {
        active = false,
        opening = true,
        stopping = true,
        status = status,
        last_result = result,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason)
            or result,
    })
end

---Record a superseded pending-open handle for later visibility.
---@param project table Project state.
---@param provider_handle table Provider pending handle.
---@param result any Cancellation/supersede result.
---@param reason? string Supersede reason.
---@param compact fun(result:any):any Compact result helper.
---@return table? entry Retained entry.
function M.retain_superseded_open(
    project,
    provider_handle,
    result,
    reason,
    compact
)
    if type(provider_handle) ~= "table" then
        return nil
    end

    local preview = preview_service.get(project) or {}
    local retained = preview.retained_open_handles
    if type(retained) ~= "table" then
        retained = {}
    end

    local entry = {
        id = M.next_generation(),
        kind = "preview-open",
        reason = reason
            or (type(result) == "table" and result.reason)
            or "superseded",
        pending = true,
        superseded = true,
        stopped = false,
        handle = provider_handle,
        result = compact and compact(result) or result,
    }
    retained[#retained + 1] = entry
    while #retained > 8 do
        table.remove(retained, 1)
    end
    preview_service.set(project, { retained_open_handles = retained })
    return entry
end

---Record completion of a retained superseded pending-open handle.
---@param project table Project state.
---@param id integer Retained entry id.
---@param final any Provider final result.
---@param compact fun(result:any):any Compact result helper.
function M.settle_retained_open(project, id, final, compact)
    local current = preview_service.get(project) or {}
    for _, item in ipairs(current.retained_open_handles or {}) do
        if item.id == id then
            item.pending = false
            item.finished = true
            item.result = compact and compact(final) or final
            break
        end
    end
    preview_service.set(project, {
        retained_open_handles = current.retained_open_handles,
    })
end

---Mark a retained superseded pending-open handle as unobservable.
---@param project table Project state.
---@param id integer Retained entry id.
function M.mark_retained_open_unobservable(project, id)
    local current = preview_service.get(project) or {}
    for _, item in ipairs(current.retained_open_handles or {}) do
        if item.id == id then
            item.unobservable = true
            break
        end
    end
    preview_service.set(project, {
        retained_open_handles = current.retained_open_handles,
    })
end

---Record a callback preview open success.
---@param project table Project state.
---@param opts? table Preview options.
---@param result any Backend result.
---@return any result Original result.
function M.to_active_callback(project, opts, result)
    M.record(project, "callback", opts, nil, nil, true)
    preview_service.set(project, {
        clear = { "opening", "open_handle", "open_generation", "open_token" },
        last_result = type(result) == "table" and result or nil,
    })
    log.add(
        "info",
        "preview opened by configured callback",
        { main = project.main, mode = opts and opts.mode }
    )
    events.emit("TypstPreviewOpened", project, {
        backend = "callback",
        mode = opts and opts.mode,
    })
    return result
end

---Record a delegated typst-preview.nvim open/toggle success.
---@param project table Project state.
---@param opts? table Preview options.
---@param result table Delegated backend result with command/cwd.
---@return boolean active True when active was recorded.
function M.to_active_delegated(project, opts, result)
    local command = result and result.command or nil
    local cwd = result and result.cwd or nil
    M.record(project, "typst-preview.nvim", opts, command, cwd, true)
    log.add("info", "preview delegated to typst-preview.nvim", {
        command = command and command[1],
        cwd = cwd,
    })
    events.emit("TypstPreviewOpened", project, {
        backend = "typst-preview.nvim",
        command = command,
        mode = opts and opts.mode,
    })
    return true
end

---Record preview backend metadata on project state.
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
            "opening",
            "open_handle",
            "open_generation",
            "open_token",
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

---Refresh last-preview metadata when reusing an active preview.
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
        and opts
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
    local command = fields.active_command or preview.active_command
    fields.last_command = type(command) == "table" and vim.deepcopy(command)
        or nil
    fields.last_cwd = fields.active_cwd or preview.active_cwd
    preview_service.set(project, fields)
end

---Record preview refresh callback metadata.
---@param project table Project state whose preview service is mutated.
---@param compile_result? table Compile/watch result that triggered refresh.
---@param refresh_result any Callback refresh result.
---@param native_active? boolean True when native preview also refreshed.
function M.record_refresh(
    project,
    compile_result,
    refresh_result,
    native_active
)
    if refresh_result == false then
        return
    end

    if native_active then
        log.add("debug", "native preview refresh callback notified", {
            main = project.main,
            cycle = compile_result and compile_result.cycle,
            code = compile_result and compile_result.code,
        })
        return
    end

    preview_service.set(project, {
        clear = { "last_command", "last_cwd" },
        last_backend = "callback-refresh",
    })
    log.add("debug", "preview refresh callback notified", {
        main = project.main,
        cycle = compile_result and compile_result.cycle,
        code = compile_result and compile_result.code,
    })
end

---Mark preview inactive and emit the stopped event.
---@param project table Project state whose preview service is mutated.
---@param backend? string Backend label to record.
---@param command? string[] Command used by delegated preview backend.
---@param cwd? string Working directory used by delegated preview backend.
---@param result? any Stop result to record before stopped event emission.
function M.emit_stopped(project, backend, command, cwd, result)
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
            "stop_handle",
            "stop_prune_reason",
            "stopping",
            "opening",
            "open_handle",
            "open_generation",
            "open_token",
        },
        active = false,
        last_backend = backend or preview.last_backend,
        last_command = command,
        last_cwd = cwd,
        last_result = type(result) == "table" and result or nil,
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

---Clear preview state without asking the backend to stop.
---@param project table Project state whose preview service is mutated.
---@param opts? table Clear options such as reason/lifecycle.
---@return boolean cleared True when active preview state was cleared.
function M.clear(project, opts)
    opts = opts or {}
    local preview = preview_service.get(project) or {}
    if not project or (preview.active ~= true and preview.opening ~= true) then
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
            "opening",
            "open_handle",
            "open_generation",
            "open_token",
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

---Return a summary-safe preview controller status.
---@param project table Project state.
---@param opts? table Status options.
---@return table status Preview state snapshot.
function M.status(project, opts)
    opts = opts or {}
    local snapshot = {}
    if type(preview_service.snapshot) == "function" then
        local ok, result = pcall(preview_service.snapshot, project)
        if ok and type(result) == "table" then
            snapshot = result
        end
    end
    if not next(snapshot) then
        snapshot = preview_service.get(project) or {}
    end
    local backend = snapshot.active and snapshot.active_backend
        or snapshot.last_backend
    local retained = snapshot.retained_open_handles or {}
    return {
        ok = true,
        active = snapshot.active == true,
        opening = snapshot.opening == true,
        stopping = snapshot.stopping == true,
        status = snapshot.status
            or (snapshot.opening and "opening")
            or (snapshot.active and "active")
            or "inactive",
        backend = backend,
        mode = snapshot.active_mode or snapshot.last_mode,
        command = snapshot.active_command or snapshot.last_command,
        cwd = snapshot.active_cwd or snapshot.last_cwd,
        url = snapshot.active_url or snapshot.last_url,
        output = snapshot.active_output,
        export = snapshot.active_export or snapshot.last_export,
        transport = snapshot.active_transport or snapshot.last_transport,
        shell = snapshot.active_shell or snapshot.last_shell,
        last_result = opts.raw and snapshot.last_result or nil,
        last_error = snapshot.last_error,
        retained_open_handles = opts.raw and retained or nil,
        retained_open_count = #retained,
        raw = opts.raw and snapshot or nil,
    }
end

return M
