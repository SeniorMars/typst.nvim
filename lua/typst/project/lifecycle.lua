local M = {}

local core_lifecycle = require("typst.core.lifecycle")
local attachments = require("typst.project.attachments")
local config = require("typst.config")
local lifecycle_events = require("typst.project.lifecycle.events")
local log = require("typst.core.log")
local main_file = require("typst.project.main_file")
local project = require("typst.project")
local project_model = require("typst.project.model")
local root_discovery = require("typst.project.root")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local deferred_import_scan_tokens = {}
local next_deferred_import_scan_token = 0
local finalize_buffer_project_transition

-- Deferred import-scan reassignment must share the same post-commit feature and
-- Tinymist finalization as normal attach so buffer/window feature signatures and
-- semantic-provider state follow the final project key.

local function buffer_path(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return util.normalize(path)
end

local function clear_deferred_import_scan(state, bufnr, token, status)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
    if not resolution or resolution.import_scan_token ~= token then
        return
    end

    resolution.import_scan_pending = false
    resolution.resolution_pending = nil
    resolution.import_scan_request = nil
    resolution.import_scan_token = nil
    resolution.import_scan_status = status or "finished"
    project_model.refresh_resolution_pending(state)
end

local function schedule_deferred_import_scan(bufnr, state, candidate)
    local resolution = candidate and candidate.resolution or nil
    local request = resolution and resolution.import_scan_request or nil
    if type(request) ~= "table" then
        return
    end

    next_deferred_import_scan_token = next_deferred_import_scan_token + 1
    local token = next_deferred_import_scan_token
    deferred_import_scan_tokens[bufnr] = token

    local stored_resolution = state.resolutions and state.resolutions[bufnr]
    if stored_resolution then
        stored_resolution.import_scan_token = token
    end

    local expected_key = state.key
    local expected_path = request.path
    local expected_config_generation = request.config_generation
        or config.generation()
    vim.defer_fn(function()
        if deferred_import_scan_tokens[bufnr] ~= token then
            return
        end
        deferred_import_scan_tokens[bufnr] = nil

        local current = project.get(bufnr)
        local function clear_current(status)
            clear_deferred_import_scan(current, bufnr, token, status)
        end

        if expected_config_generation ~= config.generation() then
            clear_current("config_changed")
            return
        end

        if not current then
            return
        end

        local current_path = buffer_path(bufnr)
        if
            not current_path or not util.same_path(current_path, expected_path)
        then
            clear_current("path_changed")
            return
        end

        if current.key ~= expected_key then
            clear_current("project_changed")
            return
        end

        local current_resolution = current.resolutions
                and current.resolutions[bufnr]
            or nil
        if not current_resolution then
            project_model.refresh_resolution_pending(current)
            return
        end

        if current_resolution.import_scan_token ~= token then
            return
        end

        local scan_started = telemetry.start()
        local ok, main, main_source, scan_root, scan_root_source = pcall(
            root_discovery.import_scan_main,
            request.path,
            request.root,
            request.root_source,
            config.unsafe_get()
        )
        telemetry.finish("project.deferred_import_scan", scan_started, {
            ok = ok,
            bufnr = bufnr,
            project_key = current.key,
            root = request.root,
        })
        if not ok then
            clear_deferred_import_scan(current, bufnr, token, "failed")
            log.add("warn", "deferred import scan failed", {
                bufnr = bufnr,
                path = request.path,
                error = main,
            })
            return
        end

        if not main then
            clear_deferred_import_scan(current, bufnr, token, "not_found")
            return
        end

        local previous_resolution = vim.deepcopy(current_resolution)
        local attach_candidate = {
            bufnr = bufnr,
            path = request.path,
            root = scan_root,
            main = main,
            previous_key = current.key,
            resolution = {
                root_source = scan_root_source,
                main_source = main_source,
                main_confidence = main_file.confidence_for_source(main_source),
                main_confidence_source = main_source,
            },
        }

        local commit_ok, next_state =
            pcall(project.commit_attach, attach_candidate)
        if not commit_ok then
            clear_deferred_import_scan(current, bufnr, token, "commit_failed")
            log.add("warn", "failed to commit deferred import-scan project", {
                bufnr = bufnr,
                path = request.path,
                main = main,
                error = next_state,
            })
            return
        end

        log.add("info", "deferred import scan resolved Typst main", {
            bufnr = bufnr,
            path = request.path,
            main = main,
            root = scan_root,
        })
        lifecycle_events.emit_reassign(
            current,
            next_state,
            bufnr,
            "deferred import scan",
            previous_resolution
        )
        lifecycle_events.stop_previous(
            current,
            "stopping compiler after deferred import scan reassigned buffer",
            "compiler stopped after deferred import scan"
        )
        finalize_buffer_project_transition(bufnr, next_state, nil, {
            reapply_features = true,
        })
    end, 20)
end

local function finalize_attach(bufnr, state, candidate)
    require("typst.integrations.tinymist").ensure(bufnr, state)
    schedule_deferred_import_scan(bufnr, state, candidate)
end

finalize_buffer_project_transition = function(bufnr, state, candidate, opts)
    opts = opts or {}
    if opts.reapply_features == true and vim.api.nvim_buf_is_valid(bufnr) then
        core_lifecycle.apply_buffer_features_all_windows(bufnr, {
            force = true,
        })
    end
    finalize_attach(bufnr, state, candidate)
end

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

        -- If resolution moved this buffer to another project, the old project
        -- may now have no buffers but still own a watcher/preview.
        lifecycle_events.emit_reassign(
            previous,
            state,
            bufnr,
            "buffer attached",
            previous_resolution
        )
        lifecycle_events.stop_previous(
            previous,
            "stopping compiler after buffer moved to another project",
            "compiler stopped after buffer moved"
        )
        finalize_buffer_project_transition(bufnr, state, candidate)
        return state
    end

    log.add("warn", candidate)
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
    deferred_import_scan_tokens[bufnr] = nil
    local previous = project.get(bufnr)
    local previous_key = previous and previous.key or nil
    local resolution = previous
            and previous.resolutions
            and vim.deepcopy(previous.resolutions[bufnr])
        or nil
    attachments.forget(bufnr, previous_key)
    local state = project.detach(bufnr)
    core_lifecycle.clear_buffer(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        util.del_buf_var(bufnr, "did_typst_nvim_ftplugin")
    end
    if state then
        lifecycle_events.emit_buffer_detach(
            state,
            bufnr,
            "buffer detached",
            resolution
        )
        lifecycle_events.emit_project_pruned(state, "buffer detached")
        lifecycle_events.stop_previous(
            state,
            "stopping compiler after last buffer detached",
            "compiler stopped after detach"
        )
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
        and not previous.resolution_pending
    then
        return previous
    end

    -- Commands call get_project lazily so changes to vim.b.typst_main,
    -- deleted main files, or renamed buffers are reflected before compile,
    -- preview, navigation, or diagnostics operate on project state.
    deferred_import_scan_tokens[bufnr] = nil
    local state = project.resolve(
        bufnr,
        previous and { ignore_project_key = previous.key } or nil
    )
    if previous and previous.key ~= state.key then
        attachments.forget(bufnr, previous.key)
    end
    lifecycle_events.emit_reassign(
        previous,
        state,
        bufnr,
        "buffer re-resolved",
        previous_resolution
    )
    lifecycle_events.stop_previous(
        previous,
        "stopping compiler after buffer main changed",
        "compiler stopped after buffer main changed"
    )
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
    if previous and previous.key ~= state.key then
        attachments.forget(bufnr, previous.key)
        lifecycle_events.emit_buffer_detach(
            previous,
            bufnr,
            "main changed",
            previous_resolution
        )
        lifecycle_events.emit_project_pruned(previous, "main changed")
        lifecycle_events.emit_project_attach(state, bufnr, "main changed")
    end
    lifecycle_events.stop_previous(
        previous,
        "stopping compiler after main changed",
        "compiler stopped after main changed"
    )
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
        if previous and previous.key ~= state.key then
            attachments.forget(bufnr, previous.key)
            lifecycle_events.emit_buffer_detach(
                previous,
                bufnr,
                "local main cleared",
                previous_resolution
            )
            lifecycle_events.emit_project_pruned(previous, "local main cleared")
            lifecycle_events.emit_project_attach(
                state,
                bufnr,
                "local main cleared"
            )
        end
        lifecycle_events.stop_previous(
            previous,
            "stopping compiler after local main cleared",
            "compiler stopped after local main cleared"
        )
        if toggle_opts.notify ~= false and notify then
            notify(("Typst project main: %s"):format(state.main))
        end
        return {
            local_main = false,
            state = state,
        }
    end

    state = project.set_main(bufnr, path)
    if previous and previous.key ~= state.key then
        attachments.forget(bufnr, previous.key)
        lifecycle_events.emit_buffer_detach(
            previous,
            bufnr,
            "local main enabled",
            previous_resolution
        )
        lifecycle_events.emit_project_pruned(previous, "local main enabled")
        lifecycle_events.emit_project_attach(state, bufnr, "local main enabled")
    end
    lifecycle_events.stop_previous(
        previous,
        "stopping compiler after local main enabled",
        "compiler stopped after local main enabled"
    )
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
---@return table state Reattached project state.
function M.reload_state(api, reload_opts, notify)
    reload_opts = reload_opts or {}
    local bufnr = normalize_bufnr(reload_opts.bufnr)
    local previous_attached = project.get(bufnr)
    local previous_resolution = previous_attached
            and previous_attached.resolutions
            and vim.deepcopy(previous_attached.resolutions[bufnr])
        or nil
    local previous = project.detach(bufnr)
    if previous then
        attachments.forget(bufnr, previous.key)
        lifecycle_events.emit_buffer_detach(
            previous,
            bufnr,
            "state reload",
            previous_resolution
        )
        lifecycle_events.emit_project_pruned(previous, "state reload")
    end

    require("typst.core.cache_registry").reload({ bufnr = bufnr })

    local state = api.attach(bufnr)
    if not state then
        error("typst.nvim: failed to reload Typst state for current buffer")
    end
    if previous and previous.key ~= state.key then
        lifecycle_events.stop_previous(
            previous,
            "stopping compiler after state reload",
            "compiler stopped after state reload"
        )
    end

    log.add(
        "info",
        "state reloaded",
        { bufnr = bufnr, main = state.main, root = state.root }
    )
    if reload_opts.notify ~= false and notify then
        notify(
            ("Reloaded Typst state: %s"):format(
                util.relpath(state.main, state.root)
            )
        )
    end
    return state
end

--- Clear lifecycle-local deferred resolver state.
function M.reset()
    deferred_import_scan_tokens = {}
    next_deferred_import_scan_token = 0
end

return M
