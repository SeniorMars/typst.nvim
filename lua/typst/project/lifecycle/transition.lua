local attachments = require("typst.project.attachments")
local core_lifecycle = require("typst.core.lifecycle")
local feature_finalize = require("typst.project.lifecycle.feature_finalize")
local lifecycle_events = require("typst.project.lifecycle.events")
local lifecycle_service = require("typst.project.services.lifecycle")
local log = require("typst.core.log")

local M = {}

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

local function compact_resolution(resolution)
    if type(resolution) ~= "table" then
        return nil
    end
    local suggestion = type(resolution.import_scan_suggestion) == "table"
            and resolution.import_scan_suggestion
        or nil
    return {
        buffer = resolution.buffer,
        root = resolution.root,
        main = resolution.main,
        root_source = resolution.root_source,
        main_source = resolution.main_source,
        resolution_pending = resolution.resolution_pending,
        import_scan_status = resolution.import_scan_status,
        import_scan_suggestion = suggestion and {
            root = suggestion.root,
            main = suggestion.main,
            root_source = suggestion.root_source,
            main_source = suggestion.main_source,
        } or nil,
    }
end

-- Single post-commit transition boundary for buffer/project ownership changes.
-- Project modules own identity; this helper owns lifecycle side effects around
-- that identity change: stale buffer-local state, events, feature finalization,
-- Tinymist ensure, deferred-scan scheduling, and old-resource stop/prune.
function M.transition_buffer(bufnr, previous, state, opts)
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
            feature_finalize.attached_buffer(bufnr, state, opts.candidate, opts)
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
            previous_resolution = compact_resolution(opts.previous_resolution),
        }
        lifecycle_service.set(state, {
            last_transition = snapshot,
        })
    end
    return result
end

return M
