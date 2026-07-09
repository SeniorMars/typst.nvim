local M = {}

local core_lifecycle = require("typst.core.lifecycle")
local attachments = require("typst.project.attachments")
local deferred_import_scan =
    require("typst.project.lifecycle.deferred_import_scan")
local lifecycle_reload = require("typst.project.lifecycle.reload")
local transition = require("typst.project.lifecycle.transition")
local log = require("typst.core.log")
local project = require("typst.project")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local transition_buffer = transition.transition_buffer

M.transition_buffer = transition.transition_buffer

--- Reapply setup-sensitive editor state for already attached Typst buffers.
---@return table summary Counts of reapplied and skipped buffers.
function M.reapply_attached_buffers()
    return attachments.reapply_attached_buffers()
end

local function attach_impl(api, bufnr)
    bufnr = normalize_bufnr(bufnr)
    local previous = project.get(bufnr)
    local previous_resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    local resolve_started = telemetry.start()
    local ok, candidate =
        pcall(project.resolve_candidate, bufnr, { import_scan = "defer" })
    telemetry.finish("project.resolve", resolve_started, {
        ok = ok,
        bufnr = bufnr,
        previous_key = previous and previous.key or nil,
        root_source = ok
                and candidate
                and candidate.resolution
                and candidate.resolution.root_source
            or nil,
        main_source = ok
                and candidate
                and candidate.resolution
                and candidate.resolution.main_source
            or nil,
        scratch = ok
                and candidate
                and candidate.resolution
                and candidate.resolution.scratch
            or nil,
    })
    if ok then
        local commit_started = telemetry.start()
        local commit_ok, state = pcall(project.commit_attach, candidate)
        telemetry.finish("project.commit_attach", commit_started, {
            ok = commit_ok,
            bufnr = bufnr,
            project_key = commit_ok and state and state.key or nil,
            root_source = candidate
                    and candidate.resolution
                    and candidate.resolution.root_source
                or nil,
            main_source = candidate
                    and candidate.resolution
                    and candidate.resolution.main_source
                or nil,
        })
        if not commit_ok then
            core_lifecycle.clear_buffer(bufnr)
            log.add("warn", "failed to commit Typst project attachment", {
                bufnr = bufnr,
                error = state,
            })
            return nil
        end

        local install_started = telemetry.start()
        local install_ok, install_err = pcall(attachments.install, api, bufnr)
        telemetry.finish("project.attach_buffers", install_started, {
            ok = install_ok,
            bufnr = bufnr,
            project_key = state.key,
        })
        if not install_ok then
            project.detach(bufnr)
            core_lifecycle.clear_buffer(bufnr)
            log.add("warn", "failed to attach Typst buffer", {
                bufnr = bufnr,
                error = install_err,
            })
            return nil
        end

        local transition = transition_buffer(bufnr, previous, state, {
            reason = "buffer attached",
            previous_resolution = previous_resolution,
            candidate = candidate,
            stop_log_message = "stopping compiler after buffer moved to another project",
            stop_prune_reason = "compiler stopped after buffer moved",
        })
        if not transition.ok then
            state.last_attach_warning = {
                ok = false,
                reason = "finalization_failed",
                message = "Typst project attached but buffer finalization failed",
                error = transition.finalization_error,
            }
        end
        return state
    end

    log.add("warn", "failed to attach Typst project", { candidate = candidate })
    return nil
end

--- Resolve, commit, and install Typst project lifecycle state for a buffer.
---@param api table Public project API facade used by buffer autocmd callbacks.
---@param bufnr? integer Buffer to attach.
---@return table|nil state Attached project state.
function M.attach(api, bufnr)
    bufnr = normalize_bufnr(bufnr)
    local started = telemetry.start()
    local state = attach_impl(api, bufnr)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
        or nil
    telemetry.finish("project.attach", started, {
        ok = state ~= nil,
        bufnr = bufnr,
        project_key = state and state.key or nil,
        root_source = resolution and resolution.root_source or nil,
        main_source = resolution and resolution.main_source or nil,
        scratch = resolution and resolution.scratch or nil,
    })
    return state
end

--- Detach a Typst buffer and emit lifecycle cleanup/events.
---@param bufnr? integer Buffer to detach.
---@return table|nil state Project state the buffer belonged to before detach.
function M.detach(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local previous = project.get(bufnr)
    deferred_import_scan.cancel(bufnr, "buffer_detached", previous)
    local resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    local state = project.detach(bufnr)
    transition_buffer(bufnr, state or previous, nil, {
        reason = "buffer detached",
        previous_resolution = resolution,
        clear_buffer = true,
        forget_previous = true,
        stop_log_message = "stopping compiler after last buffer detached",
        stop_prune_reason = "compiler stopped after detach",
    })
    if vim.api.nvim_buf_is_valid(bufnr) then
        util.del_buf_var(bufnr, "did_typst_nvim_ftplugin")
    end
    return state
end

--- Return a fresh project state for a buffer, re-resolving stale main choices.
---@param bufnr? integer Buffer whose Typst project should be resolved.
---@return table state Project state associated with the buffer.
function M.get_project(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local previous = project.get(bufnr)
    local previous_resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    if
        previous
        and not core_lifecycle.explicit_main_changed(bufnr, previous)
        and not project.main_stale(previous, bufnr)
    then
        local suggestion, suggestion_resolution =
            deferred_import_scan.suggestion(previous, bufnr)
        if suggestion then
            local accepted = deferred_import_scan.consume(
                bufnr,
                previous,
                suggestion,
                suggestion_resolution
            )
            if accepted then
                local accepted_previous_resolution = vim.deepcopy(
                    suggestion_resolution
                        or (previous.resolutions and previous.resolutions[bufnr])
                        or {}
                )
                transition_buffer(bufnr, previous, accepted, {
                    reason = "import scan suggestion accepted",
                    previous_resolution = accepted_previous_resolution,
                    reapply_features = true,
                    schedule_deferred = false,
                    stop_log_message = "stopping compiler after import scan suggestion changed main",
                    stop_prune_reason = "compiler stopped after import scan suggestion",
                })
                return accepted
            end
        end
        if previous.resolution_pending == "import_scan" then
            return previous
        end
        if not previous.resolution_pending then
            return previous
        end
    end

    -- Commands call get_project lazily so changes to vim.b.typst_main,
    -- deleted main files, or renamed buffers are reflected before compile,
    -- preview, navigation, or diagnostics operate on project state.
    deferred_import_scan.cancel(bufnr, "buffer_reresolved", previous)
    local state = project.resolve(
        bufnr,
        previous and { ignore_project_key = previous.key } or nil
    )
    transition_buffer(bufnr, previous, state, {
        reason = "buffer re-resolved",
        previous_resolution = previous_resolution,
        reapply_features = true,
        schedule_deferred = false,
        stop_log_message = "stopping compiler after buffer main changed",
        stop_prune_reason = "compiler stopped after buffer main changed",
    })
    return state
end

--- Set an explicit main file for a buffer and reattach project services.
---@param path string Main Typst file path selected by the user.
---@param bufnr? integer Buffer receiving the explicit main setting.
---@param set_opts? table Main-file persistence and resolution options.
---@param notify? fun(message:string, level?:integer)
---@return table state Project state after the main-file change.
function M.set_main(path, bufnr, set_opts, notify)
    set_opts = set_opts or {}
    bufnr = normalize_bufnr(bufnr)
    local previous = project.get(bufnr)
    local previous_resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    local state = project.set_main(bufnr, path, set_opts)
    transition_buffer(bufnr, previous, state, {
        reason = "main changed",
        previous_resolution = previous_resolution,
        reapply_features = true,
        schedule_deferred = false,
        stop_log_message = "stopping compiler after main changed",
        stop_prune_reason = "compiler stopped after main changed",
    })
    if notify then
        notify(("Typst main: %s"):format(state.main))
    end
    return state
end

--- Toggle the current buffer between local-main and project-main behavior.
---@param toggle_opts? table Toggle controls, including `bufnr` and `notify`.
---@param notify? fun(message:string, level?:integer)
---@return table result Toggle result with `local_main` and project `state`.
function M.toggle_main(toggle_opts, notify)
    toggle_opts = toggle_opts or {}
    local bufnr = normalize_bufnr(toggle_opts.bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        error("typst.nvim: current buffer has no file name")
    end

    path = util.normalize(path)
    local previous = project.get(bufnr)
    local previous_resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    local current = util.get_buf_var(bufnr, "typst_main")
    local local_main = type(current) == "string"
        and current ~= ""
        and util.same_path(current, path)
    local state

    if local_main then
        state = project.clear_main(bufnr, { clear_persisted = false })
        transition_buffer(bufnr, previous, state, {
            reason = "local main cleared",
            previous_resolution = previous_resolution,
            reapply_features = true,
            schedule_deferred = false,
            stop_log_message = "stopping compiler after local main cleared",
            stop_prune_reason = "compiler stopped after local main cleared",
        })
        if toggle_opts.notify ~= false and notify then
            notify(("Typst project main: %s"):format(state.main))
        end
        return {
            local_main = false,
            state = state,
        }
    end

    state = project.set_main(bufnr, path)
    transition_buffer(bufnr, previous, state, {
        reason = "local main enabled",
        previous_resolution = previous_resolution,
        reapply_features = true,
        schedule_deferred = false,
        stop_log_message = "stopping compiler after local main enabled",
        stop_prune_reason = "compiler stopped after local main enabled",
    })
    if toggle_opts.notify ~= false and notify then
        notify(("Typst local main: %s"):format(state.main))
    end
    return {
        local_main = true,
        state = state,
    }
end

--- Rebuild project attachment and metadata caches for a buffer.
---@param api table Public project API facade used to reattach the buffer.
---@param reload_opts? table Reload controls, including `bufnr` and `notify`.
---@param notify? fun(message:string, level?:integer)
---@return table|nil state Reattached project state.
---@return table? err Structured reload failure.
function M.reload_state(api, reload_opts, notify)
    return lifecycle_reload.reload_state(api, reload_opts, notify)
end

--- Clear lifecycle-local deferred resolver state.
function M.reset()
    deferred_import_scan.reset("lifecycle_reset")
end

function M._deferred_import_scan_state()
    return deferred_import_scan.state()
end

return M
