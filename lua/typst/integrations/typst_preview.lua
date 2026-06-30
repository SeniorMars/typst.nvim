local M = {}

local config = require("typst.config")
local events = require("typst.core.events")
local log = require("typst.core.log")
local pending_handle = require("typst.core.pending")
local restart_handle = require("typst.core.restart_handle")
local preview_service = require("typst.project.services.preview")
local preview_capabilities =
    require("typst.integrations.typst_preview.capabilities")
local native = require("typst.preview.native")
local runtime = require("typst.integrations.typst_preview.runtime")
local source_sync = require("typst.integrations.typst_preview.source_sync")
local state = require("typst.integrations.typst_preview.state")

M.own_command_definition = runtime.own_command_definition
M.own_stop_command_definition = runtime.own_stop_command_definition
M.own_toggle_command_definition = runtime.own_toggle_command_definition
M.own_inverse_command_definition = runtime.own_inverse_command_definition

local callback_error = preview_capabilities.callback_error

local function subscribe_on_finish(handle, callback)
    local style = type(handle) == "table"
            and (handle.on_finish_style or handle._typst_on_finish_style)
        or nil
    if style then
        return pending_handle.subscribe(handle, callback, { style = style })
    end

    -- Legacy typst-preview.nvim callback handles are dot-style. typst.nvim-owned
    -- handles set `on_finish_style = "colon"` so they do not rely on guessing.
    local ok, result =
        pending_handle.subscribe(handle, callback, { style = "dot" })
    if ok then
        return ok, result
    end
    return pending_handle.subscribe(handle, callback)
end

local function restart_stop_failed(result)
    return type(result) == "table"
        and (result.ok == false or result.stopped == false)
end

local function pending_unobservable(stage, err)
    return {
        ok = false,
        reason = "finish_subscription_failed",
        message = ("Pending Typst preview %s could not be observed"):format(
            stage
        ),
        error = err,
    }
end

local function record_stop_failed(project, result)
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

local function record_open_failed(project, result)
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
        status = "open_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason)
            or result,
    })
end

local function open_after_pending_stop(project, stop_handle, opts)
    local handle =
        restart_handle.new({ kind = "preview" }):set_stop_handle(stop_handle)

    local function complete_stop(stop_result)
        if handle.result ~= nil or handle.cancel_requested then
            return
        end
        handle.stopping = false
        handle.stop_result = stop_result

        if restart_stop_failed(stop_result) then
            record_stop_failed(project, stop_result)
            handle.ok = false
            handle.reason = stop_result.reason or "stop_failed"
            handle.message = stop_result.message
            handle:finish(stop_result)
            return
        end

        local preview_state = preview_service.get(project) or {}
        if preview_state.active == true or preview_state.stopping == true then
            state.emit_stopped(project, "callback", nil, nil)
        end

        local open_opts = vim.deepcopy(opts or {})
        open_opts.restart = false
        open_opts.lifecycle = nil

        local ok, open_result = xpcall(function()
            return M.open(project, open_opts)
        end, debug.traceback)
        if not ok then
            open_result = callback_error(project, "open", open_result)
        end

        handle:set_next_handle(open_result)
        if type(open_result) == "table" and open_result.pending == true then
            handle.pending = true
            if type(open_result.on_finish) == "function" then
                local subscribed, subscribe_error = subscribe_on_finish(
                    open_result,
                    function(result)
                        if type(result) == "table" and result.ok == false then
                            record_open_failed(project, result)
                        end
                        handle:finish(result)
                    end
                )
                if subscribed then
                    return
                end
                local failed = pending_unobservable("open", subscribe_error)
                record_open_failed(project, failed)
                handle:finish(failed)
                return
            end
            local failed = pending_unobservable("open")
            record_open_failed(project, failed)
            handle:finish(failed)
            return
        end

        if type(open_result) == "table" and open_result.ok == false then
            record_open_failed(project, open_result)
        end

        handle:finish(open_result)
    end

    if type(stop_handle) == "table" and stop_handle.pending == true then
        if type(stop_handle.on_finish) ~= "function" then
            local failed = pending_unobservable("stop")
            record_stop_failed(project, failed)
            handle:finish(failed)
            return handle
        end
        local subscribed, subscribe_error = subscribe_on_finish(
            stop_handle,
            function(result)
                complete_stop(result)
            end
        )
        if not subscribed then
            local failed = pending_unobservable("stop", subscribe_error)
            record_stop_failed(project, failed)
            handle:finish(failed)
        end
    else
        vim.schedule(function()
            complete_stop(stop_handle)
        end)
    end

    return handle
end

-- Integration layer for preview backends.
--
-- Preference order is configured callbacks, native typst.nvim preview, then
-- explicit compatibility delegation to typst-preview.nvim. Preview state is
-- project-local so multiple Typst roots can be active without sharing backend
-- metadata.
--- Check whether typst-preview.nvim can be required.
---@return boolean available True when the plugin module is available.
---@return any error Error from `require`, when unavailable.
function M.available()
    return runtime.available()
end

--- Check whether a preview command belongs to another preview backend.
---@param name? string Command name to check.
---@return boolean available True when a non-typst.nvim command exists.
function M.command_available(name)
    return runtime.command_available(name)
end

--- Clear active preview state without invoking a backend stop command.
---@param project table Project state whose preview service is cleared.
---@param opts? table Clear options such as reason/lifecycle.
---@return boolean cleared True when active preview state was cleared.
function M.clear_state(project, opts)
    return state.clear(project, opts)
end

local function prepare_open(project, preview, opts)
    local preview_state = preview_service.get(project) or {}
    if preview_state.active ~= true then
        return true
    end

    if preview.reuse ~= false and opts.restart ~= true then
        -- Reuse avoids tearing down typst-preview.nvim on every :TypstPreview;
        -- watch refresh and source sync can continue against the active backend.
        state.record_reused(project, opts)
        local current_preview = preview_service.get(project) or {}
        log.add("debug", "preview already active; reusing existing preview", {
            main = project.main,
            backend = current_preview.last_backend,
            mode = current_preview.last_mode,
        })
        return false, true
    end

    local result = M.stop(
        project,
        vim.tbl_extend("force", vim.deepcopy(opts), {
            lifecycle = true,
            restart = true,
        })
    )
    if type(result) == "table" and result.pending == true then
        return false, open_after_pending_stop(project, result, opts)
    end
    if type(result) == "table" and result.ok == false then
        return false, result
    end

    if result == false then
        return false, false
    end

    return true
end

local function delegate_to_typst_preview(preview)
    return preview.provider == "typst-preview.nvim"
end

local function active_native_browser(project)
    return (preview_service.get(project) or {}).active_backend
        == "native-browser"
end

local function native_stop_result(project, result)
    if
        type(result) == "table"
        and (result.ok == false or result.stopped == false)
    then
        return result
    end
    if result == false then
        return false
    end

    native.stop(project)
    state.emit_stopped(project, "native-browser", nil, project.root)
    return result == nil and true or result
end

local function native_stop_after_pending(project, pending)
    if type(pending) ~= "table" or type(pending.on_finish) ~= "function" then
        return pending
    end

    preview_service.set(project, { stopping = true })
    local callbacks = {}
    local cancelled = false
    local handle = {
        pending = true,
    }

    function handle.on_finish(self_or_callback, maybe_callback)
        local callback = self_or_callback == handle and maybe_callback
            or self_or_callback
        if type(callback) == "function" then
            callbacks[#callbacks + 1] = callback
        end
        return handle
    end

    if type(pending.cancel) == "function" then
        handle.cancel = function(_, opts)
            cancelled = true
            local ok, cancel_result = pcall(pending.cancel, pending, opts)
            if not ok then
                cancel_result = {
                    ok = false,
                    reason = "cancel_error",
                    message = "Typst preview stop cancellation failed",
                    error = cancel_result,
                }
            end
            handle.pending = false
            handle.result = cancel_result
            return cancel_result
        end
    end

    local subscribed, subscribe_error = subscribe_on_finish(
        pending,
        function(result)
            if cancelled then
                return
            end
            handle.pending = false
            handle.result = native_stop_result(project, result)
            for _, callback in ipairs(callbacks) do
                callback(handle.result)
            end
        end
    )
    if not subscribed then
        handle.pending = false
        handle.result = {
            ok = false,
            reason = "finish_subscription_failed",
            message = "Pending native browser preview stop could not be observed",
            error = subscribe_error,
        }
    end

    return handle
end

local function native_refresh_payload(native_result, refresh_result)
    local payload = {
        native = native_result,
        callback = refresh_result,
    }
    if type(native_result) == "table" and native_result.ok == false then
        payload.ok = false
        payload.reason = native_result.reason
        payload.message = native_result.message
        payload.error = native_result.error
    end
    return payload
end

local function native_refresh_after_pending(native_result, refresh_result)
    local callbacks = {}
    local handle = vim.tbl_extend(
        "force",
        native_refresh_payload(native_result, refresh_result),
        {
            pending = true,
            kind = "preview-refresh",
            handle = native_result,
        }
    )

    function handle:on_finish(callback)
        if type(callback) ~= "function" then
            return self
        end
        if self.result ~= nil then
            pcall(callback, self.result, self)
        else
            callbacks[#callbacks + 1] = callback
        end
        return self
    end

    local function finish(result)
        if handle.result ~= nil then
            return handle.result
        end
        handle.pending = false
        handle.result = native_refresh_payload(result, refresh_result)
        for _, callback in ipairs(callbacks) do
            pcall(callback, handle.result, handle)
        end
        callbacks = {}
        return handle.result
    end

    local subscribed, subscribe_error =
        subscribe_on_finish(native_result, finish)
    if not subscribed then
        return native_refresh_payload({
            ok = false,
            reason = "finish_subscription_failed",
            message = "Pending native browser preview refresh could not be observed",
            error = subscribe_error,
        }, refresh_result)
    end

    function handle.cancel(self_or_opts, maybe_opts)
        local opts = self_or_opts == handle and maybe_opts or self_or_opts
        if handle.result ~= nil then
            return false, handle.result
        end
        if type(native_result.cancel) ~= "function" then
            local result = finish({
                ok = false,
                reason = opts and opts.reason or "cancelled",
                stopped = true,
            })
            return true, result
        end
        local ok, stopped, result =
            pcall(native_result.cancel, native_result, opts)
        if not ok then
            result = finish({
                ok = false,
                reason = "cancel_failed",
                message = tostring(stopped),
                stopped = false,
            })
            return false, result
        end
        if type(result) ~= "table" or result.pending ~= true then
            result = finish(result or {
                ok = false,
                reason = opts and opts.reason or "cancelled",
                stopped = stopped ~= false,
            })
        end
        return stopped ~= false, result
    end

    return handle
end

--- Open a preview backend for a project, reusing active state when allowed.
---@param project table Project state whose main file should be previewed.
---@param opts? table Preview controls such as mode, restart, and reuse behavior.
---@return boolean|table|string|nil result Backend result, pending stop/open handle, viewer path, or false on reuse/stop failure.
function M.open(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local should_open, prepared = prepare_open(project, preview, opts)
    if not should_open then
        return prepared
    end

    if type(preview.open) == "function" then
        local ok, result = pcall(preview.open, project, opts)
        if not ok then
            return callback_error(project, "open", result)
        end
        if type(result) == "table" and result.ok == false then
            return result
        end
        if result ~= false then
            state.record(project, "callback", opts, nil, nil, true)
            log.add(
                "info",
                "preview opened by configured callback",
                { main = project.main, mode = opts.mode }
            )
            events.emit("TypstPreviewOpened", project, {
                backend = "callback",
                mode = opts.mode,
            })
        end
        return result
    end

    if preview.provider == nil or preview.provider == "native" then
        return native.open(project, opts)
    end

    if
        delegate_to_typst_preview(preview)
        and runtime.command_available("TypstPreview")
    then
        -- Do not require users to configure typst-preview.nvim twice. If its
        -- command already exists and is not typst.nvim's own shim, delegate from
        -- the main buffer with the project root as cwd.
        local command = "TypstPreview"
        if opts.mode and opts.mode ~= "" then
            command = command .. " " .. opts.mode
        end

        local cwd = runtime.run_from_main(project, command)

        local preview_command = { command }
        state.record(
            project,
            "typst-preview.nvim",
            opts,
            preview_command,
            cwd,
            true
        )
        log.add(
            "info",
            "preview delegated to typst-preview.nvim",
            { command = command, cwd = cwd }
        )
        events.emit("TypstPreviewOpened", project, {
            backend = "typst-preview.nvim",
            command = preview_command,
            mode = opts.mode,
        })
        return true
    end

    if preview.fallback == "view" then
        log.add(
            "warn",
            "preview backend unavailable; falling back to viewer",
            { main = project.main, provider = preview.provider }
        )
        return native.open_viewer(project, opts)
    end

    error(
        "typst.nvim: preview backend is unavailable; configure preview.open or use :TypstView"
    )
end

--- Stop the active preview backend for a project.
---@param project table Project state whose preview service owns backend state.
---@param opts? table Stop controls forwarded to configured preview callbacks.
---@return boolean|table|nil result Stop status, pending handle, or unsupported failure payload.
function M.stop(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native_active = active_native_browser(project)

    if native_active and type(preview.stop) == "function" then
        local ok, result = pcall(preview.stop, project, opts)
        if not ok then
            native.stop(project)
            state.emit_stopped(project, "native-browser", nil, project.root)
            return callback_error(project, "stop", result)
        end
        if type(result) == "table" and result.pending == true then
            log.add("info", "native preview stop callback is pending", {
                main = project.main,
                backend = "native-browser",
            })
            return native_stop_after_pending(project, result)
        end
        return native_stop_result(project, result)
    end

    if type(preview.stop) == "function" then
        local ok, result = pcall(preview.stop, project, opts)
        if not ok then
            return callback_error(project, "stop", result)
        end
        if type(result) == "table" then
            if result.pending == true then
                -- Leave active=true while an async stop is pending. Clearing it
                -- early would let a restart race with the still-running preview.
                preview_service.set(project, { stopping = true })
                log.add("info", "preview stop is pending", {
                    main = project.main,
                    backend = (preview_service.get(project) or {}).last_backend,
                })
                return result
            end
            if result.ok == false or result.stopped == false then
                return result
            end
        end
        if result ~= false then
            state.emit_stopped(project, "callback", nil, nil)
        end
        return result
    end

    local preview_state = preview_service.get(project) or {}
    if native_active or preview_state.active_backend == "native-browser" then
        native.stop(project, opts)
        state.emit_stopped(project, "native-browser", nil, project.root)
        return true
    end

    if
        delegate_to_typst_preview(preview)
        and runtime.command_available("TypstPreviewStop")
    then
        local command = "TypstPreviewStop"
        local cwd = runtime.run_from_main(project, command)
        state.emit_stopped(project, "typst-preview.nvim", { command }, cwd)
        return true
    end

    local result = {
        ok = false,
        reason = "unsupported",
        message = "No Typst preview stop backend is configured",
    }
    log.add("warn", "preview stop unsupported", {
        main = project.main,
        backend = (preview_service.get(project) or {}).last_backend,
    })
    return result
end

--- Notify a configured preview refresh callback after compile/watch output.
---@param project table Project state whose preview should be refreshed.
---@param result? table Compile/watch result that triggered the refresh.
---@param opts? table Refresh controls forwarded to the configured callback.
---@return any result Callback result, nil when refresh is not configured, or failure payload.
function M.refresh(project, result, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native_result = nil
    local native_active = active_native_browser(project)
    if native_active then
        native_result = native.refresh(project, result, opts)
    end

    if type(preview.refresh) ~= "function" then
        return native_result
    end

    local ok, refresh_result = pcall(preview.refresh, project, result, opts)
    if not ok then
        log.add("warn", "preview refresh callback failed", {
            main = project.main,
            error = refresh_result,
        })
        return {
            ok = false,
            reason = "callback_error",
            provider = "callback",
            error = refresh_result,
            native = native_result,
        }
    end

    if refresh_result ~= false and not native_active then
        preview_service.set(project, {
            clear = { "last_command", "last_cwd" },
            last_backend = "callback-refresh",
        })
        log.add("debug", "preview refresh callback notified", {
            main = project.main,
            cycle = result and result.cycle,
            code = result and result.code,
        })
    elseif refresh_result ~= false then
        log.add("debug", "native preview refresh callback notified", {
            main = project.main,
            cycle = result and result.cycle,
            code = result and result.code,
        })
    end

    if native_active then
        if type(native_result) == "table" and native_result.pending == true then
            return native_refresh_after_pending(native_result, refresh_result)
        end
        return native_refresh_payload(native_result, refresh_result)
    end
    return refresh_result
end

--- Toggle preview state through typst-preview.nvim or configured open/stop hooks.
---@param project table Project state whose preview should be toggled.
---@param opts? table Toggle controls, including preview mode.
---@return boolean|table|string|nil result New preview state or backend result payload.
function M.toggle(project, opts)
    opts = opts or {}

    local preview = config.unsafe_get().preview
    if
        delegate_to_typst_preview(preview)
        and runtime.command_available("TypstPreviewToggle")
    then
        local preview_state = preview_service.get(project) or {}
        local was_active = preview_state.active == true
        local command = "TypstPreviewToggle"
        local cwd = runtime.run_from_main(project, command)
        if was_active then
            state.emit_stopped(project, "typst-preview.nvim", { command }, cwd)
            return false
        end

        preview_service.set(project, {
            active = true,
            last_backend = "typst-preview.nvim",
            last_command = { command },
            last_cwd = cwd,
            active_backend = "typst-preview.nvim",
            active_mode = opts.mode,
            active_command = { command },
            active_cwd = cwd,
        })
        events.emit("TypstPreviewOpened", project, {
            backend = "typst-preview.nvim",
            command = { command },
            mode = opts.mode,
        })
        return true
    end

    if (preview_service.get(project) or {}).active then
        return M.stop(project, opts)
    end

    return M.open(project, opts)
end

--- Forward-search through the active preview backend.
---@param project table Project state that provides source and preview context.
---@param opts? table Source location options such as line, column, and path.
---@return table|boolean|nil result Source-sync result or unsupported failure payload.
function M.forward(project, opts)
    return source_sync.forward(project, opts)
end

--- Inverse-search from preview coordinates back into a Typst source buffer.
---@param project table Project state used to resolve source paths.
---@param opts? table Preview inverse-search location options.
---@return table|boolean|nil result Source location result or unsupported failure payload.
function M.inverse(project, opts)
    return source_sync.inverse(project, opts)
end

--- Return preview source-sync capabilities for a project.
---@param project table Project state used to inspect preview configuration.
---@return table capabilities Preview capability flags.
function M.capabilities(project)
    return source_sync.capabilities(project)
end

return M
