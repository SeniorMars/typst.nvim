local M = {}

-- Preview lifecycle policy enters here. Concrete open/stop/refresh behavior
-- lives behind preview backends, and service mutations go through the preview
-- state machine.

local config = require("typst.config")
local log = require("typst.core.log")
local preview_backend = require("typst.preview.backend")
local preview_pending = require("typst.preview.pending")
local preview_results = require("typst.preview.results")
local preview_status = require("typst.preview.status")
local delegated = require("typst.preview.backends.delegated")
local source_sync = require("typst.preview.source_sync")
local state = require("typst.preview.state_machine")

M.own_command_definition = delegated.own_command_definition
M.own_stop_command_definition = delegated.own_stop_command_definition
M.own_toggle_command_definition = delegated.own_toggle_command_definition
M.own_inverse_command_definition = delegated.own_inverse_command_definition

local callback_error = preview_results.callback_error
local record_stop_failed = state.to_stopping_failed
local record_stop_unconfirmed = state.to_stop_unconfirmed
local cancel_pending_open = preview_pending.cancel_current_open
local observe_pending_open = preview_pending.observe_open

local function open_after_pending_stop(project, stop_handle, opts)
    return preview_pending.open_after_stop(project, stop_handle, opts, M.open)
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
    return delegated.available()
end

--- Check whether a preview command belongs to another preview backend.
---@param name? string Command name to check.
---@return boolean available True when a non-typst.nvim command exists.
function M.command_available(name)
    return delegated.command_available(name)
end

--- Clear active preview state without invoking a backend stop command.
---@param project table Project state whose preview service is cleared.
---@param opts? table Clear options such as reason/lifecycle.
---@return boolean cleared True when active preview state was cleared.
function M.clear_state(project, opts)
    local cancel_opts = vim.tbl_extend("force", opts or {}, {
        force = true,
        supersede = true,
    })
    if cancel_pending_open(project, cancel_opts) ~= nil then
        return true
    end
    return state.clear(project, opts)
end

local function prepare_open(project, preview, opts)
    local preview_state = state.current(project)
    if preview_state.opening == true then
        if preview.reuse ~= false and opts.restart ~= true then
            log.add("debug", "preview open already pending; reusing handle", {
                main = project.main,
                backend = preview_state.last_backend,
                mode = preview_state.last_mode,
            })
            return false, preview_state.open_handle or true
        end

        local cancelled = cancel_pending_open(
            project,
            { reason = "restart", supersede = true }
        )
        if type(cancelled) == "table" and cancelled.ok == false then
            return false, cancelled
        end
    end

    if preview_state.active ~= true then
        return true
    end

    if preview.reuse ~= false and opts.restart ~= true then
        -- Reuse avoids tearing down typst-preview.nvim on every :TypstPreview;
        -- watch refresh and source sync can continue against the active backend.
        state.record_reused(project, opts)
        local current_preview = state.current(project)
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

    local backend, backend_err = preview_backend.resolve(project, opts)
    if not backend then
        return backend_err
    end

    if backend.kind == "custom" or backend.kind == "callback" then
        local result = backend:open(project, opts)
        if type(result) == "table" and result.ok == false then
            return result
        end
        if type(result) == "table" and result.pending == true then
            return observe_pending_open(project, opts, result)
        end
        if result ~= false then
            state.to_active_callback(project, opts, result)
        end
        return result
    end

    if backend.kind == "browser" or backend.kind == "viewer" then
        return backend:open(project, opts)
    end

    if backend.kind == "delegated" then
        -- Do not require users to configure typst-preview.nvim twice. If its
        -- command already exists and is not typst.nvim's own shim, delegate from
        -- the main buffer with the project root as cwd.
        local result = backend:open(project, opts)
        if type(result) == "table" and result.ok == false then
            return result
        end
        return state.to_active_delegated(project, opts, result)
    end

    return backend_err
end

--- Stop the active preview backend for a project.
---@param project table Project state whose preview service owns backend state.
---@param opts? table Stop controls forwarded to configured preview callbacks.
---@return boolean|table|nil result Stop status, pending handle, or unsupported failure payload.
function M.stop(project, opts)
    opts = opts or {}
    local cancelled_open = cancel_pending_open(project, opts)
    if cancelled_open ~= nil then
        return cancelled_open
    end

    return preview_backend.stop(project, opts)
end

--- Stop preview during global exit cleanup.
---
--- VimLeavePre cannot rely on later scheduled callbacks, so a pending callback
--- provider stop is recorded as unconfirmed instead of clearing active state.
---@param project table Project state whose preview service owns backend state.
---@param opts? table Stop controls forwarded to configured preview callbacks.
---@return boolean|table|nil result Stop status or unconfirmed pending payload.
function M.stop_for_exit(project, opts)
    opts = vim.tbl_extend("force", {
        lifecycle = true,
        exit = true,
        reason = "exit",
    }, opts or {})
    local ok, result = pcall(M.stop, project, opts)
    if not ok then
        result = callback_error(project, "stop", result)
        record_stop_failed(project, result)
        return result
    end

    if type(result) == "table" and result.pending == true then
        record_stop_unconfirmed(project, result, opts.reason or "exit")
        log.add("warn", "preview stop remained pending during exit", {
            main = project.main,
            backend = state.current(project).last_backend,
        })
        return result
    end

    if preview_results.stop_failed(result) then
        record_stop_failed(project, result)
        log.add("warn", "preview stop failed during exit", {
            main = project.main,
            result = result,
        })
    end

    return result
end

--- Notify a configured preview refresh callback after compile/watch output.
---@param project table Project state whose preview should be refreshed.
---@param result? table Compile/watch result that triggered the refresh.
---@param opts? table Refresh controls forwarded to the configured callback.
---@return any result Callback result, nil when refresh is not configured, or failure payload.
function M.refresh(project, result, opts)
    return preview_backend.refresh(project, result, opts)
end

--- Toggle preview state through typst-preview.nvim or configured open/stop hooks.
---@param project table Project state whose preview should be toggled.
---@param opts? table Toggle controls, including preview mode.
---@return boolean|table|string|nil result New preview state or backend result payload.
function M.toggle(project, opts)
    return preview_backend.toggle(project, opts, M.open, M.stop)
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

---Return preview controller status for a project.
---@param project table Project state.
---@param opts? table Status options.
---@return table status Preview status payload.
function M.status(project, opts)
    return preview_status.snapshot(project, opts)
end

return M
