local attachments = require("typst.project.attachments")
local core_lifecycle = require("typst.core.lifecycle")
local lifecycle_service = require("typst.project.services.lifecycle")
local log = require("typst.core.log")
local project = require("typst.project")
local project_model = require("typst.project.model")
local telemetry = require("typst.core.telemetry")
local transition = require("typst.project.lifecycle.transition")
local util = require("typst.core.util")

local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
local transition_buffer = transition.transition_buffer

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

    local transition_result = transition_buffer(
        bufnr,
        previous_attached,
        state,
        {
            reason = "state reloaded",
            previous_resolution = previous_resolution,
            candidate = candidate,
            reapply_features = true,
            stop_log_message = "stopping compiler after state reload reassigned buffer",
            stop_prune_reason = "compiler stopped after state reload",
        }
    )
    if not transition_result.ok then
        state.last_attach_warning = {
            ok = false,
            reason = "finalization_failed",
            message = "Typst project reloaded but buffer finalization failed",
            error = transition_result.finalization_error,
        }
    end

    return state
end

---Rebuild project attachment and metadata caches for a buffer.
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

return M
