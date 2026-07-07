local config = require("typst.config")
local log = require("typst.core.log")
local native = require("typst.preview.native")
local preview_pending = require("typst.preview.pending")
local results = require("typst.preview.results")
local state = require("typst.preview.state_machine")

local M = {}

---Return true when preview config explicitly delegates to typst-preview.nvim.
---@param preview table Preview config.
---@return boolean delegated True when delegated.
function M.delegates_to_typst_preview(preview)
    return preview and preview.provider == "typst-preview.nvim"
end

local function delegated()
    return require("typst.preview.backends.delegated")
end

local function callback_backend(preview)
    return require("typst.preview.backends.callback").create(preview)
end

---Return whether the active preview is the native browser backend.
---@param project table Project state.
---@return boolean active True when native browser preview is active.
function M.active_native_browser(project)
    return state.current(project).active_backend == "native-browser"
end

---Record native preview stop once the configured/native stop completed.
---@param project table Project state.
---@param result any Stop result.
---@return any result Normalized stop result.
function M.native_stop_result(project, result)
    if type(result) == "table" and results.stop_failed(result) then
        return result
    end
    if result == false then
        return false
    end

    native.stop(project)
    return state.to_inactive(
        project,
        "native-browser",
        nil,
        project.root,
        result == nil and true or result
    )
end

---Stop the active preview backend.
---@param project table Project state.
---@param opts? table Stop options.
---@return any result Stop result.
function M.stop(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native_active = M.active_native_browser(project)

    if native_active and type(preview.stop) == "function" then
        local ok, result = pcall(preview.stop, project, opts)
        if not ok then
            native.stop(project)
            local failure = results.callback_error(project, "stop", result)
            failure.stopped = true
            failure.backend_stopped = true
            failure.warning = true
            return state.to_inactive(
                project,
                "native-browser",
                nil,
                project.root,
                failure
            )
        end
        if type(result) == "table" and result.pending == true then
            log.add("info", "native preview stop callback is pending", {
                main = project.main,
                backend = "native-browser",
            })
            return preview_pending.native_stop_after_pending(
                project,
                result,
                M.native_stop_result
            )
        end
        return M.native_stop_result(project, result)
    end

    if type(preview.stop) == "function" then
        local result = callback_backend(preview):stop(project, opts)
        if type(result) == "table" then
            if result.pending == true then
                state.to_stopping(project, { handle = result })
                log.add("info", "preview stop is pending", {
                    main = project.main,
                    backend = state.current(project).last_backend,
                })
                return result
            end
            if result.stopped == true then
                state.to_inactive(project, "callback", nil, nil, result)
                return result
            end
            if result.ok == false or result.stopped == false then
                return result
            end
        end
        if result ~= false then
            state.to_inactive(project, "callback", nil, nil, result)
        end
        return result
    end

    local preview_state = state.current(project)
    if native_active or preview_state.active_backend == "native-browser" then
        native.stop(project)
        return state.to_inactive(
            project,
            "native-browser",
            nil,
            project.root,
            true
        )
    end

    if
        M.delegates_to_typst_preview(preview)
        and delegated().command_available("TypstPreviewStop")
    then
        local result = delegated().create(preview):stop(project, opts)
        if type(result) == "table" and result.ok == false then
            return result
        end
        state.to_inactive(
            project,
            "typst-preview.nvim",
            result.command,
            result.cwd,
            true
        )
        return true
    end

    local result = {
        ok = false,
        reason = "unsupported",
        message = "No Typst preview stop backend is configured",
    }
    log.add("warn", "preview stop unsupported", {
        main = project.main,
        backend = state.current(project).last_backend,
    })
    return result
end

---Refresh the active preview backends after compiler output changes.
---@param project table Project state.
---@param compile_result? table Compile/watch result.
---@param opts? table Refresh options.
---@return any result Refresh result.
function M.refresh(project, compile_result, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native_result = nil
    local native_active = M.active_native_browser(project)
    if native_active then
        native_result = native.refresh(project, compile_result, opts)
    end

    if type(preview.refresh) ~= "function" then
        return native_result
    end

    local refresh_result =
        callback_backend(preview):refresh(project, compile_result, opts)
    if type(refresh_result) == "table" and refresh_result.ok == false then
        refresh_result.native = native_result
        return refresh_result
    end

    state.record_refresh(project, compile_result, refresh_result, native_active)

    if native_active then
        if type(native_result) == "table" and native_result.pending == true then
            return preview_pending.native_refresh_after_pending(
                project,
                native_result,
                refresh_result
            )
        end
        return preview_pending.refresh_payload(native_result, refresh_result)
    end
    return refresh_result
end

---Toggle preview through delegated toggle or controller open/stop callbacks.
---@param project table Project state.
---@param opts? table Toggle options.
---@param open_fn fun(project:table, opts:table):any
---@param stop_fn fun(project:table, opts:table):any
---@return any result Toggle result.
function M.toggle(project, opts, open_fn, stop_fn)
    opts = opts or {}

    local preview = config.unsafe_get().preview
    if
        M.delegates_to_typst_preview(preview)
        and delegated().command_available("TypstPreviewToggle")
    then
        local preview_state = state.current(project)
        local was_active = preview_state.active == true
        local result = delegated().create(preview):toggle(project, opts)
        if type(result) == "table" and result.ok == false then
            return result
        end
        if was_active then
            state.to_inactive(
                project,
                "typst-preview.nvim",
                result.command,
                result.cwd,
                false
            )
            return false
        end

        return state.to_active_delegated(project, opts, result)
    end

    if state.is_active(project) then
        return stop_fn(project, opts)
    end

    return open_fn(project, opts)
end

---Resolve the preferred preview backend for an open operation.
---@param _project table Project state.
---@param _opts? table Preview options.
---@return table? backend Backend wrapper.
---@return table? err Structured error when no backend is available.
function M.resolve(_project, _opts)
    local preview = config.unsafe_get().preview or {}

    if type(preview.open) == "function" then
        return require("typst.preview.backends.callback").create(preview)
    end

    if preview.provider == nil or preview.provider == "native" then
        return require("typst.preview.backends.native").create(preview)
    end

    if
        M.delegates_to_typst_preview(preview)
        and require("typst.preview.backends.delegated").command_available(
            "TypstPreview"
        )
    then
        return require("typst.preview.backends.delegated").create(preview)
    end

    if preview.fallback == "view" then
        return require("typst.preview.backends.viewer_fallback").create(preview)
    end

    return nil,
        results.failed(
            "preview_backend_unavailable",
            "Typst preview backend is unavailable; configure preview.open or use :TypstView",
            { provider = preview.provider }
        )
end

return M
