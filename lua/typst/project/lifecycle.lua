local M = {}

local core_lifecycle = require("typst.core.lifecycle")
local attachments = require("typst.project.attachments")
local config = require("typst.config")
local lifecycle_events = require("typst.project.lifecycle.events")
local log = require("typst.core.log")
local main_file = require("typst.project.main_file")
local project = require("typst.project")
local project_model = require("typst.project.model")
local integration_service = require("typst.project.services.integrations")
local lifecycle_service = require("typst.project.services.lifecycle")
local root_discovery = require("typst.project.root")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local deferred_import_scan_tokens = {}
local next_deferred_import_scan_token = 0
local transition_buffer

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
    for _, entry in ipairs(resolution.trace or {}) do
        if entry.stage == "import_scan" and entry.status == "deferred" then
            entry.status = status or "finished"
            entry.settled = true
            break
        end
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
        local trace = vim.deepcopy(current_resolution.trace or {})
        local updated_import_scan_trace = false
        for _, entry in ipairs(trace) do
            if entry.stage == "import_scan" then
                entry.status = "matched"
                entry.settled = true
                entry.main = main
                entry.source = main_source
                entry.root = scan_root
                entry.root_source = scan_root_source
                entry.confidence = main_file.confidence_for_source(main_source)
                updated_import_scan_trace = true
                break
            end
        end
        if not updated_import_scan_trace then
            trace[#trace + 1] = {
                stage = "import_scan",
                status = "matched",
                settled = true,
                main = main,
                source = main_source,
                root = scan_root,
                root_source = scan_root_source,
                confidence = main_file.confidence_for_source(main_source),
                line_limit = root_discovery.import_scan_line_limit(),
            }
        end
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
                import_scan_line_limit = root_discovery.import_scan_line_limit(),
                trace = trace,
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
        transition_buffer(bufnr, current, next_state, {
            reason = "deferred import scan",
            previous_resolution = previous_resolution,
            reapply_features = true,
            schedule_deferred = false,
            stop_log_message = "stopping compiler after deferred import scan reassigned buffer",
            stop_prune_reason = "compiler stopped after deferred import scan",
        })
    end, 20)
end

local function finalize_attached_buffer(bufnr, state, candidate, opts)
    opts = opts or {}
    if opts.reapply_features == true and vim.api.nvim_buf_is_valid(bufnr) then
        core_lifecycle.apply_buffer_features_all_windows(bufnr, {
            force = true,
        })
    end
    local tinymist_ok, tinymist_reason =
        require("typst.integrations.tinymist").ensure(bufnr, state)
    integration_service.set_tinymist(state, {
        ok = tinymist_ok == true,
        reason = tinymist_reason,
        bufnr = bufnr,
        mode = require("typst.integrations.tinymist").lsp_mode(),
    })
    if opts.schedule_deferred ~= false then
        schedule_deferred_import_scan(bufnr, state, candidate)
    end
end

local function stop_messages(opts)
    opts = opts or {}
    return opts.stop_log_message or ("stopping compiler after %s"):format(
        opts.reason or "buffer project transition"
    ),
        opts.stop_prune_reason or ("compiler stopped after %s"):format(
            opts.reason or "buffer project transition"
        )
end

local function stop_previous_project(previous, opts)
    if not previous then
        return false
    end
    local log_message, prune_reason = stop_messages(opts)
    return lifecycle_events.stop_previous(previous, log_message, prune_reason)
end

-- Single post-commit transition boundary for buffer/project ownership changes.
-- Project modules own identity; this helper owns lifecycle side effects around
-- that identity change: stale buffer-local state, events, feature finalization,
-- Tinymist ensure, deferred-scan scheduling, and old-resource stop/prune.
transition_buffer = function(bufnr, previous, state, opts)
    opts = opts or {}
    local previous_key = previous and previous.key or nil
    local state_key = state and state.key or nil
    local changed = previous_key ~= state_key
    local previous_stop_requested = false

    if changed and previous_key and opts.forget_previous ~= false then
        attachments.forget(bufnr, previous_key)
    end

    if opts.clear_buffer == true then
        core_lifecycle.clear_buffer(bufnr)
    end

    local finalization_error = nil
    if state then
        local finalize_ok, finalize_err = xpcall(function()
            finalize_attached_buffer(bufnr, state, opts.candidate, opts)
        end, debug.traceback)
        if not finalize_ok then
            finalization_error = tostring(finalize_err)
            log.add("warn", "buffer project finalization failed", {
                bufnr = bufnr,
                project_key = state.key,
                reason = opts.reason,
                error = finalization_error,
            })
        end
    end

    if opts.emit_events ~= false then
        if state then
            local attach_extra = {
                finalization_ok = finalization_error == nil,
                finalization_error = finalization_error,
            }
            lifecycle_events.emit_reassign(
                previous,
                state,
                bufnr,
                opts.reason or "buffer project transition",
                opts.previous_resolution,
                attach_extra
            )
        elseif previous then
            lifecycle_events.emit_buffer_detach(
                previous,
                bufnr,
                opts.reason or "buffer detached",
                opts.previous_resolution
            )
            lifecycle_events.emit_project_pruned(
                previous,
                opts.reason or "buffer detached"
            )
        end
    end

    if
        opts.stop_previous ~= false
        and previous
        and (changed or state == nil or opts.stop_even_if_same == true)
    then
        previous_stop_requested = stop_previous_project(previous, opts) == true
    end

    local result = {
        ok = finalization_error == nil,
        state = state,
        previous_stop_requested = previous_stop_requested,
        emitted_events = opts.emit_events ~= false,
        finalization_error = finalization_error,
        reason = opts.reason or "buffer project transition",
        bufnr = bufnr,
        previous_key = previous_key,
        project_key = state_key,
    }
    if state then
        local snapshot = {
            ok = result.ok,
            previous_stop_requested = result.previous_stop_requested,
            emitted_events = result.emitted_events,
            finalization_error = result.finalization_error,
            reason = result.reason,
            bufnr = result.bufnr,
            previous_key = result.previous_key,
            project_key = result.project_key,
        }
        lifecycle_service.set(state, {
            last_transition = snapshot,
        })
    end
    return result
end

M.transition_buffer = transition_buffer

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
    deferred_import_scan_tokens[bufnr] = nil
    local previous = project.get(bufnr)
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

local function restore_previous_reload_attachment(
    api,
    bufnr,
    previous_attached,
    previous_resolution
)
    if not previous_attached then
        return nil, "no_previous_project"
    end

    local path = previous_resolution and previous_resolution.buffer
        or buffer_path(bufnr)
        or previous_attached.main
    local restored_ok, restored = pcall(project.commit_attach, {
        root = previous_attached.root,
        main = previous_attached.main,
        bufnr = bufnr,
        path = path,
        resolution = previous_resolution,
    })
    if not restored_ok or not restored then
        local direct_ok, direct = pcall(function()
            local project_store = require("typst.project.store")
            local graph_sources = require("typst.project.graph.sources")
            local resolution = vim.tbl_extend("force", {
                buffer = path,
                root_source = previous_attached.root_source
                    or "reload rollback",
                main_source = previous_attached.main_source
                    or "reload rollback",
            }, previous_resolution or {})

            previous_attached.bufs = previous_attached.bufs or {}
            previous_attached.resolutions = previous_attached.resolutions or {}
            previous_attached.bufs[bufnr] = true
            previous_attached.resolutions[bufnr] = resolution
            previous_attached.last_resolution = resolution
            previous_attached.root_source = resolution.root_source
            previous_attached.main_source = resolution.main_source
            previous_attached.main_confidence = resolution.main_confidence
            previous_attached.main_confidence_source =
                resolution.main_confidence_source
            project_model.refresh_resolution_pending(previous_attached)
            graph_sources.add(
                previous_attached,
                path,
                project_model.association_source_for(
                    path,
                    previous_attached.main,
                    resolution
                )
            )
            graph_sources.add(
                previous_attached,
                previous_attached.main,
                "explicit"
            )
            project_store.restore(previous_attached)
            project_store.set_buffer(bufnr, previous_attached.key)
            return previous_attached
        end)
        if not direct_ok or not direct then
            return nil,
                ("%s; direct restore failed: %s"):format(
                    tostring(restored),
                    tostring(direct)
                )
        end
        restored = direct
    end

    local install_ok, install_err = pcall(attachments.install, api, bufnr)
    if not install_ok then
        project.detach(bufnr)
        core_lifecycle.clear_buffer(bufnr)
        return nil, tostring(install_err), restored.key
    end

    transition_buffer(bufnr, nil, restored, {
        reason = "state reload rollback",
        previous_resolution = previous_resolution,
        reapply_features = true,
        schedule_deferred = false,
        stop_previous = false,
    })
    return restored, nil, restored.key
end

local function rollback_reload_failure(
    api,
    bufnr,
    previous_attached,
    previous_resolution
)
    if not previous_attached then
        core_lifecycle.clear_buffer(bufnr)
        return false, nil, nil
    end

    local restored, restore_err, restored_key =
        restore_previous_reload_attachment(
            api,
            bufnr,
            previous_attached,
            previous_resolution
        )
    return restored ~= nil, restore_err, restored_key
end

local function cleanup_failed_reload_candidate(
    candidate,
    bufnr,
    previous_attached
)
    if type(candidate) ~= "table" then
        return
    end

    local project_store = require("typst.project.store")
    local candidate_key =
        project_store.project_key(candidate.root, candidate.main)
    if
        type(candidate_key) ~= "string"
        or (previous_attached and candidate_key == previous_attached.key)
    then
        return
    end

    local failed = project_store.get(candidate_key)
    if type(failed) ~= "table" then
        return
    end

    -- commit_attach can fail after create_or_update has created the candidate
    -- project and marked this buffer in its project-local membership, but before
    -- the global buffer->project mapping is updated. Remove that partial state
    -- so rollback does not leave a ghost project that still appears attached.
    attachments.forget(bufnr, candidate_key)
    if failed.bufs then
        failed.bufs[bufnr] = nil
    end
    if failed.resolutions then
        failed.resolutions[bufnr] = nil
    end
    project_model.refresh_resolution_pending(failed)
    project_store.prune(failed, "failed reload candidate")
end

local function reload_attach_two_phase(
    api,
    bufnr,
    previous_attached,
    previous_resolution
)
    local resolve_started = telemetry.start()
    local resolve_ok, candidate =
        pcall(project.resolve_candidate, bufnr, { import_scan = "defer" })
    telemetry.finish("project.reload.resolve", resolve_started, {
        ok = resolve_ok,
        bufnr = bufnr,
        previous_key = previous_attached and previous_attached.key or nil,
        root_source = resolve_ok
                and candidate
                and candidate.resolution
                and candidate.resolution.root_source
            or nil,
        main_source = resolve_ok
                and candidate
                and candidate.resolution
                and candidate.resolution.main_source
            or nil,
    })
    if not resolve_ok then
        return nil,
            {
                stage = "resolve",
                error = tostring(candidate),
            }
    end

    -- Reload is two-phase at the project-membership boundary. This pre-install
    -- is intentionally side-effectful; rollback must restore previous hooks and
    -- state if install or commit fails. Installed autocmd callbacks must resolve
    -- project identity lazily from bufnr; they must not capture the candidate or
    -- previous project at install time.
    local install_started = telemetry.start()
    local install_ok, install_err = pcall(attachments.install, api, bufnr)
    telemetry.finish("project.reload.install", install_started, {
        ok = install_ok,
        bufnr = bufnr,
        previous_key = previous_attached and previous_attached.key or nil,
    })
    if not install_ok then
        local rollback_ok, rollback_error, rollback_project_key =
            rollback_reload_failure(
                api,
                bufnr,
                previous_attached,
                previous_resolution
            )
        return nil,
            {
                stage = "install",
                error = tostring(install_err),
                rollback_ok = rollback_ok,
                rollback_error = rollback_error,
                rollback_project_key = rollback_project_key,
            }
    end

    local commit_started = telemetry.start()
    local commit_ok, state = pcall(project.commit_attach, candidate)
    telemetry.finish("project.reload.commit", commit_started, {
        ok = commit_ok,
        bufnr = bufnr,
        project_key = commit_ok and state and state.key or nil,
    })
    if not commit_ok or not state then
        cleanup_failed_reload_candidate(candidate, bufnr, previous_attached)
        local rollback_ok, rollback_error, rollback_project_key =
            rollback_reload_failure(
                api,
                bufnr,
                previous_attached,
                previous_resolution
            )
        return nil,
            {
                stage = "commit",
                error = tostring(state),
                rollback_ok = rollback_ok,
                rollback_error = rollback_error,
                rollback_project_key = rollback_project_key,
            }
    end

    local transition = transition_buffer(bufnr, previous_attached, state, {
        reason = "state reloaded",
        previous_resolution = previous_resolution,
        candidate = candidate,
        reapply_features = true,
        stop_log_message = "stopping compiler after state reload reassigned buffer",
        stop_prune_reason = "compiler stopped after state reload",
    })
    if not transition.ok then
        state.last_attach_warning = {
            ok = false,
            reason = "finalization_failed",
            message = "Typst project reloaded but buffer finalization failed",
            error = transition.finalization_error,
        }
    end

    return state
end

--- Rebuild project attachment and metadata caches for a buffer.
---@param api table Public project API facade used to reattach the buffer.
---@param reload_opts? table Reload controls, including `bufnr` and `notify`.
---@param notify? fun(message:string, level?:integer)
---@return table|nil state Reattached project state.
---@return table? err Structured reload failure.
function M.reload_state(api, reload_opts, notify)
    reload_opts = reload_opts or {}
    local bufnr = normalize_bufnr(reload_opts.bufnr)
    local cache_reload =
        require("typst.core.cache_registry").reload({ bufnr = bufnr })
    local previous_attached = project.get(bufnr)
    local previous_resolution = previous_attached
            and previous_attached.resolutions
            and vim.deepcopy(previous_attached.resolutions[bufnr])
        or nil

    local state, reload_err = reload_attach_two_phase(
        api,
        bufnr,
        previous_attached,
        previous_resolution
    )
    if not state then
        reload_err = reload_err or {}
        local err = {
            ok = false,
            reason = "reload_failed",
            operation = "project.reload_state",
            bufnr = bufnr,
            message = "Failed to reload Typst state for current buffer",
            stage = reload_err.stage,
            error = reload_err.error,
            previous_project_key = previous_attached and previous_attached.key
                or nil,
            rollback_ok = reload_err.rollback_ok == true,
            rollback_error = reload_err.rollback_error,
            rollback_project_key = reload_err.rollback_project_key,
            cache_reload = cache_reload,
        }
        log.add("warn", "state reload failed", err)
        if reload_opts.notify ~= false and notify then
            notify(err.message, vim.log.levels.ERROR)
        end
        return nil, err
    end

    lifecycle_service.set(state, {
        last_reload_cache = cache_reload,
    })
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
